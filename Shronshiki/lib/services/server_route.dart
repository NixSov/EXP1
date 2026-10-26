import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Как приложение ходит к Supabase.
enum RouteMode { auto, direct, proxy }

/// Выбор пути к Supabase: напрямую или через посредника (Deno Deploy).
///
/// У части провайдеров supabase.co недоступен или отвечает по 5–10 секунд,
/// у других — работает лучше посредника. В режиме «Авто» приложение меряет оба
/// пути, ходит более быстрым и переключается на ходу, если путь перестал работать.
class ServerRoute extends ChangeNotifier {
  ServerRoute._(this._prefs, {required this.supabaseUrl, required this.proxyUrl});

  static const _kMode = 'route_mode';
  static const _kLastProxy = 'route_last_proxy';

  /// Прямой путь медленнее этого — считаем плохим.
  static const _slow = Duration(milliseconds: 2500);

  final SharedPreferences _prefs;
  final Uri supabaseUrl;

  /// Адрес посредника; null — посредник не настроен.
  final Uri? proxyUrl;

  bool _useProxy = false;
  int? lastDirectMs;
  int? lastProxyMs;
  DateTime? _lastProbe;
  bool _probing = false;
  int _slowDirectInARow = 0;

  static Future<ServerRoute> create({required String supabaseUrl, required String proxyUrl}) async {
    final prefs = await SharedPreferences.getInstance();
    final route = ServerRoute._(
      prefs,
      supabaseUrl: Uri.parse(supabaseUrl),
      proxyUrl: proxyUrl.trim().isEmpty ? null : Uri.parse(proxyUrl.trim().replaceAll(RegExp(r'/+$'), '')),
    );
    // Пока не померили — начинаем с пути, который сработал в прошлый раз.
    route._useProxy = route.hasProxy && (prefs.getBool(_kLastProxy) ?? false);
    route._applyMode();
    return route;
  }

  bool get hasProxy => proxyUrl != null;

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
    final how = usingProxy ? 'через посредника' : 'напрямую';
    return ms == null ? how : '$how, $ms мс';
  }

  void _setUseProxy(bool value) {
    if (_useProxy == value) return;
    _useProxy = value;
    _prefs.setBool(_kLastProxy, value);
    debugPrint('server route: ${value ? 'proxy' : 'direct'}');
    notifyListeners();
  }

  /// Меряет оба пути и выбирает (в режиме «Авто»). Не чаще раза в 20 секунд.
  Future<void> probe({bool force = false}) async {
    if (mode != RouteMode.auto || !hasProxy || _probing) return;
    if (!force && _lastProbe != null && DateTime.now().difference(_lastProbe!) < const Duration(seconds: 20)) {
      return;
    }
    _probing = true;
    _lastProbe = DateTime.now();
    try {
      final results = await Future.wait([
        _measure(supabaseUrl.replace(path: '/auth/v1/health')),
        _measure(proxyUrl!.replace(path: '${proxyUrl!.path}/health')),
      ]);
      lastDirectMs = results[0];
      lastProxyMs = results[1];
      final direct = results[0];
      final proxy = results[1];
      if (direct != null && direct < _slow.inMilliseconds) {
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

  /// Время ответа в мс или null, если не ответил за 5 секунд.
  static Future<int?> _measure(Uri url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final sw = Stopwatch()..start();
    try {
      final request = await client.getUrl(url).timeout(const Duration(seconds: 5));
      request.persistentConnection = false;
      final response = await request.close().timeout(const Duration(seconds: 5));
      await response.drain<void>().timeout(const Duration(seconds: 5));
      // 401 на /auth/v1/health без ключа — тоже ответ: сервер доступен.
      return response.statusCode < 500 ? sw.elapsedMilliseconds : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// HTTP-клиент для Supabase: выбирает путь для каждого запроса.
  http.Client createClient() => _RoutingClient(this);

  Uri _toProxy(Uri url) => url.replace(
        scheme: proxyUrl!.scheme,
        host: proxyUrl!.host,
        port: proxyUrl!.hasPort ? proxyUrl!.port : null,
        path: '${proxyUrl!.path}${url.path}',
      );

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

  void _reportProxy({required bool failed}) {
    // Посредник тоже не отвечает — пробуем снова оба пути.
    if (failed) unawaited(probe(force: true));
  }
}

/// Каждый запрос — новое соединение (некоторые провайдеры обрывают долгие
/// соединения с зарубежными серверами). Запросы к Supabase идут выбранным путём;
/// если соединиться не удалось, запрос повторяется другим путём.
class _RoutingClient extends http.BaseClient {
  _RoutingClient(this._route);

  final ServerRoute _route;
  final http.Client _inner = IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 6));
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

    final viaProxy = _route.usingProxy;
    final auto = _route.mode == RouteMode.auto;
    final first = _copy(request, viaProxy ? _route._toProxy(request.url) : request.url);
    final sw = Stopwatch()..start();
    try {
      var sending = _inner.send(first ?? (request..persistentConnection = false));
      // Провайдер может не рвать соединение, а «подвешивать» его. Ждать 20 секунд
      // не будем: через 6 секунд повторим запрос через посредника.
      if (!viaProxy && auto) sending = sending.timeout(const Duration(seconds: 6));
      final response = await sending;
      if (viaProxy) {
        _route._reportProxy(failed: response.statusCode == 502);
      } else {
        _route._reportDirect(failed: false, ms: sw.elapsedMilliseconds);
      }
      return response;
    } catch (e) {
      if (!_isConnectionProblem(e)) rethrow;
      if (viaProxy) {
        _route._reportProxy(failed: true);
      } else {
        _route._reportDirect(failed: true);
      }
      final retry = _copy(request, viaProxy ? request.url : _route._toProxy(request.url));
      if (retry == null || !auto) rethrow;
      return _inner.send(retry);
    }
  }

  /// Сеть не пустила запрос (или подвесила его) — пробуем другим путём.
  /// Ответ сервера с ошибкой (4xx/5xx) сюда не попадает: это не сетевая проблема.
  static bool _isConnectionProblem(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is HandshakeException ||
      e is http.ClientException;

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
