import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'net/platform_http.dart';
import 'usage_meter.dart';

/// Как приложение ходит к Supabase.
enum RouteMode { auto, direct, proxy }

/// Выбор пути к Supabase: напрямую или через посредника (Vercel, Deno Deploy).
///
/// У части провайдеров supabase.co недоступен или отвечает по 5–10 секунд,
/// у других — работает лучше посредника. В режиме «Авто» приложение меряет
/// прямой путь и всех посредников, ходит самым быстрым и переключается на ходу,
/// если путь перестал работать. Посредников несколько — на случай, если у одного
/// кончился лимит бесплатного тарифа или его заблокировали.
class ServerRoute extends ChangeNotifier {
  ServerRoute._(this._prefs, {required this.supabaseUrl, required this.proxies})
      : _proxy = proxies.firstOrNull;

  static const _kMode = 'route_mode';
  static const _kLastProxy = 'route_last_proxy';
  static const _kLastProxyUrl = 'route_last_proxy_url';

  /// Прямой путь медленнее этого — считаем плохим.
  static const _slow = Duration(milliseconds: 2500);

  final SharedPreferences _prefs;
  final Uri supabaseUrl;

  /// Все посредники из настроек.
  final List<Uri> proxies;

  /// Посредник, через которого идём сейчас (самый быстрый из ответивших).
  Uri? _proxy;
  Uri? get proxyUrl => _proxy;

  /// Время ответа каждого посредника при последнем замере (null — не ответил).
  final Map<Uri, int?> proxyMs = {};

  /// Посредники в порядке попыток: сначала текущий, потом остальные.
  List<Uri> get _proxyOrder => [
        ?_proxy,
        ...proxies.where((p) => p != _proxy),
      ];

  bool _useProxy = false;
  int? lastDirectMs;
  int? lastProxyMs;
  DateTime? _lastProbe;
  bool _probing = false;
  int _slowDirectInARow = 0;

  /// [proxyUrl] — один адрес или несколько через запятую.
  static Future<ServerRoute> create({required String supabaseUrl, required String proxyUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    final route = ServerRoute._(
      prefs,
      supabaseUrl: Uri.parse(supabaseUrl),
      proxies: parseProxies(proxyUrl),
    );
    // Пока не померили — начинаем с пути, который сработал в прошлый раз.
    route._useProxy = route.hasProxy && (prefs.getBool(_kLastProxy) ?? false);
    final last = prefs.getString(_kLastProxyUrl);
    route._proxy = route.proxies.where((p) => p.toString() == last).firstOrNull ?? route._proxy;
    route._applyMode();
    return route;
  }

  bool get hasProxy => proxies.isNotEmpty;

  static List<Uri> parseProxies(String raw) => [
        for (final part in raw.split(RegExp(r'[,\s]+')))
          if (part.trim().isNotEmpty) Uri.parse(part.trim().replaceAll(RegExp(r'/+$'), '')),
      ];

  RouteMode get mode => RouteMode.values.asNameMap()[_prefs.getString(_kMode)] ?? RouteMode.auto;
  set mode(RouteMode value) {
    _prefs.setString(_kMode, value.name);
    _applyMode();
    notifyListeners();
    if (value == RouteMode.auto) unawaited(probe(force: true));
  }

  void _applyMode() {
    switch (mode) {
      case RouteMode.direct:
        _useProxy = false;
      case RouteMode.proxy:
        _useProxy = hasProxy;
      case RouteMode.auto:
        if (!hasProxy) _useProxy = false;
    }
  }

  bool get usingProxy => _useProxy;

  String get description {
    final ms = usingProxy ? lastProxyMs : lastDirectMs;
    final how = usingProxy ? 'через посредника ${_proxy?.host ?? ''}' : 'напрямую';
    return ms == null ? how : '$how, $ms мс';
  }

  void _setProxy(Uri value) {
    if (_proxy == value) return;
    _proxy = value;
    _prefs.setString(_kLastProxyUrl, value.toString());
    debugPrint('server route: proxy $value');
  }

  void _setUseProxy(bool value) {
    if (_useProxy == value) return;
    _useProxy = value;
    _prefs.setBool(_kLastProxy, value);
    debugPrint('server route: ${value ? 'proxy' : 'direct'}');
    notifyListeners();
  }

  /// Меряет оба пути и выбирает (в режиме «Авто»). Не чаще раза в 20 секунд.
  /// В режиме «Посредник» тоже меряем — чтобы выбрать живого посредника.
  Future<void> probe({bool force = false}) async {
    if (mode == RouteMode.direct || !hasProxy || _probing) return;
    if (!force && _lastProbe != null && DateTime.now().difference(_lastProbe!) < const Duration(seconds: 20)) {
      return;
    }
    _probing = true;
    _lastProbe = DateTime.now();
    try {
      final results = await Future.wait([
        _measure(supabaseUrl.replace(path: '/auth/v1/health')),
        for (final p in proxies) _measure(p.replace(path: '${p.path}/health')),
      ]);
      final direct = results[0];
      // Самый быстрый из ответивших посредников.
      int? proxy;
      for (var i = 0; i < proxies.length; i++) {
        final ms = results[i + 1];
        proxyMs[proxies[i]] = ms;
        if (ms != null && (proxy == null || ms < proxy)) {
          proxy = ms;
          _setProxy(proxies[i]);
        }
      }
      lastDirectMs = direct;
      lastProxyMs = proxy;
      if (mode != RouteMode.auto) {
        // «Посредник»: прямой путь не используем, только выбрали посредника.
      } else if (direct != null && direct < _slow.inMilliseconds) {
        // Прямой путь в порядке — он не тратит лимит посредника.
        _setUseProxy(false);
      } else if (proxy != null) {
        _setUseProxy(true);
      }
      _slowDirectInARow = 0;
      notifyListeners();
    } finally {
      _probing = false;
    }
  }

  static Future<int?> _measure(Uri url) => measureUrl(url);

  /// HTTP-клиент для Supabase: выбирает путь для каждого запроса.
  http.Client createClient() => _RoutingClient(this);

  Uri _toProxy(Uri url, [Uri? proxy]) {
    final p = proxy ?? proxyUrl!;
    // Собираем адрес заново: replace(port: null) оставил бы порт исходного адреса.
    return Uri(
      scheme: p.scheme,
      host: p.host,
      port: p.hasPort ? p.port : null,
      path: '${p.path}${url.path}',
      query: url.hasQuery ? url.query : null,
    );
  }

  bool _isSupabase(Uri url) => url.host == supabaseUrl.host;

  /// Результат запроса напрямую — для переключения на ходу.
  void _reportDirect({required bool failed, int? ms}) {
    if (mode != RouteMode.auto || !hasProxy) return;
    if (failed) {
      _setUseProxy(true);
      return;
    }
    if (ms != null && ms > _slow.inMilliseconds) {
      _slowDirectInARow++;
      if (_slowDirectInARow >= 2) _setUseProxy(true);
    } else {
      _slowDirectInARow = 0;
    }
  }

  /// Посредник не ответил — переходим на следующего и перемеряем всех.
  void _proxyFailed(Uri proxy) {
    proxyMs[proxy] = null;
    if (proxy == _proxy && proxies.length > 1) {
      _setProxy(proxies[(proxies.indexOf(proxy) + 1) % proxies.length]);
    }
    unawaited(probe());
  }

  /// Запрос прошёл через посредника — дальше ходим через него.
  void _proxyWorked(Uri proxy) {
    _setProxy(proxy);
    if (!_useProxy && mode != RouteMode.direct) _setUseProxy(true);
  }
}

/// Каждый запрос — новое соединение (некоторые провайдеры обрывают долгие
/// соединения с зарубежными серверами). Запросы к Supabase идут выбранным путём;
/// если соединиться не удалось, запрос повторяется другим путём.
class _RoutingClient extends http.BaseClient {
  _RoutingClient(this._route);

  final ServerRoute _route;
  final http.Client _inner = newHttpClient();
  Timer? _reprobe;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!_route._isSupabase(request.url) || !_route.hasProxy) {
      request.persistentConnection = false;
      return _inner.send(request);
    }
    // Пока ходим через посредника, иногда проверяем, не ожил ли прямой путь.
    if (_route.usingProxy) {
      _reprobe ??= Timer(const Duration(minutes: 2), () {
        _reprobe = null;
        unawaited(_route.probe());
      });
    }

    final auto = _route.mode == RouteMode.auto;
    // Пути по порядку попыток: выбранный, потом остальные посредники, потом
    // (в «Авто») другой путь. null — напрямую.
    final proxies = _route._proxyOrder;
    final paths = <Uri?>[
      if (_route.usingProxy) ...[...proxies, if (auto) null] else ...[null, if (auto) ...proxies],
    ];
    for (var i = 0; i < paths.length; i++) {
      final via = paths[i];
      final last = i == paths.length - 1;
      final envelope = via != null && _isEnvelopeProxy(via);
      final attempt = _copy(request, via == null || envelope ? request.url : _route._toProxy(request.url, via));
      // Посреднику на Apps Script запрос нужно упаковать — без копии не получится.
      if (envelope && attempt == null) continue;
      // Тело повторно отправить можно только у http.Request — иначе одна попытка.
      final canRetry = attempt != null && !last;
      if (via != null) UsageMeter.countProxyRequest();
      final sw = Stopwatch()..start();
      try {
        var sending = envelope
            ? _sendEnvelope(attempt!, via)
            : _inner.send(attempt ?? (request..persistentConnection = false));
        // Провайдер может не рвать соединение, а «подвешивать» его. Долго не ждём:
        // напрямую — 6 секунд, через посредника — 15, потом пробуем другой путь.
        if (canRetry) sending = sending.timeout(Duration(seconds: via == null ? 6 : 15));
        final response = await sending;
        if (via != null && _proxyDown(response) && canRetry) {
          // Посредник не работает (приостановлен за лимиты, ошибка шлюза) — дальше.
          unawaited(response.stream.drain<void>().catchError((_) {}));
          _route._proxyFailed(via);
          continue;
        }
        if (via == null) {
          _route._reportDirect(failed: false, ms: sw.elapsedMilliseconds);
        } else {
          _route._proxyWorked(via);
        }
        return response;
      } catch (e) {
        if (!_isConnectionProblem(e) || !canRetry) rethrow;
        if (via == null) {
          _route._reportDirect(failed: true);
        } else {
          _route._proxyFailed(via);
        }
      }
    }
    throw StateError('no route to server');
  }

  /// Посредник на Google Apps Script: он не видит заголовков запроса, поэтому
  /// запрос едет упакованным в JSON (см. proxy/apps_script_proxy.gs).
  static bool _isEnvelopeProxy(Uri proxy) => proxy.path.contains('/macros/s/');

  Future<http.StreamedResponse> _sendEnvelope(http.Request request, Uri proxy) async {
    final envelope = jsonEncode({
      'm': request.method,
      'p': request.url.path,
      'q': request.url.hasQuery ? request.url.query : null,
      'h': {for (final e in request.headers.entries) e.key.toLowerCase(): e.value},
      'b': request.bodyBytes.isEmpty ? null : utf8.decode(request.bodyBytes, allowMalformed: true),
    });
    // text/plain — чтобы браузер не делал предварительный CORS-запрос.
    final post = http.Request('POST', proxy)
      ..headers['content-type'] = 'text/plain;charset=utf-8'
      ..body = envelope
      ..followRedirects = false
      ..persistentConnection = false;
    var response = await _inner.send(post).timeout(const Duration(seconds: 25));
    var body = await response.stream.bytesToString();
    // Google отвечает перенаправлением на script.googleusercontent.com, где лежит
    // результат; браузер проходит его сам, на телефоне и ПК — вручную.
    final location = response.headers['location'];
    if (location != null && response.statusCode >= 300 && response.statusCode < 400) {
      final get = http.Request('GET', Uri.parse(location))..persistentConnection = false;
      response = await _inner.send(get).timeout(const Duration(seconds: 25));
      body = await response.stream.bytesToString();
    }
    final Map<String, dynamic> reply;
    try {
      reply = Map<String, dynamic>.from(jsonDecode(body) as Map);
    } catch (_) {
      // Страница ошибки Google (лимит, сбой) вместо ответа — посредник не работает.
      throw http.ClientException('Apps Script ответил не JSON (${response.statusCode})', proxy);
    }
    final bytes = utf8.encode(reply['b'] as String? ?? '');
    return http.StreamedResponse(
      Stream.value(bytes),
      (reply['s'] as num?)?.toInt() ?? 502,
      contentLength: bytes.length,
      headers: {
        for (final e in Map<String, dynamic>.from(reply['h'] as Map? ?? const {}).entries) e.key: '${e.value}',
      },
      request: request,
    );
  }

  /// Ответ самого посредника или его площадки, а не Supabase: приложение
  /// приостановлено, не выложено или шлюз не достучался до сервера.
  static bool _proxyDown(http.StreamedResponse r) =>
      r.statusCode == 502 ||
      r.statusCode == 503 ||
      r.statusCode == 504 ||
      r.headers.containsKey('x-deno-error') ||
      r.headers.containsKey('x-vercel-error');

  /// Сеть не пустила запрос (или подвесила его) — пробуем другим путём.
  /// Ответ сервера с ошибкой (4xx/5xx) сюда не попадает: это не сетевая проблема.
  static bool _isConnectionProblem(Object e) => isConnectionError(e);

  /// Копия запроса с другим адресом (тело повторно отправить можно только у http.Request).
  static http.Request? _copy(http.BaseRequest original, Uri url) {
    if (original is! http.Request) return null;
    final copy = http.Request(original.method, url)
      ..headers.addAll(original.headers)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = false;
    copy.bodyBytes = original.bodyBytes;
    return copy;
  }

  @override
  void close() {
    _reprobe?.cancel();
    _inner.close();
  }
}
