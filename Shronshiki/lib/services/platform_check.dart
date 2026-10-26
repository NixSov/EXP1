import 'dart:async';
import 'dart:io';

import '../app_state.dart';
import 'diagnostics.dart';

/// Проверка площадок: какие сервисы доступны из текущей сети (например, без VPN).
/// Для каждой — серия коротких запросов и одна большая загрузка: провайдеры
/// иногда пропускают короткий ответ, но обрывают соединение после ~16 КБ.
class PlatformCheck {
  static const _small = 5;
  static const _bigBytes = 100 * 1024;

  static List<({String title, List<String> small, String? big, Map<String, String> headers})>
      get _platforms {
    final config = AppState.instance.config;
    return [
      (
        title: 'Google Firebase',
        small: const [
          'https://firestore.googleapis.com/',
          'https://identitytoolkit.googleapis.com/',
        ],
        big: 'https://www.googleapis.com/discovery/v1/apis',
        headers: const {},
      ),
      (
        title: 'Deno Deploy',
        small: const ['https://fresh.deno.dev/'],
        big: 'https://deno.com/',
        headers: const {},
      ),
      (
        title: 'Netlify',
        small: const ['https://gatsby-starter-blog-demo.netlify.app/'],
        big: 'https://www.netlify.com/',
        headers: const {},
      ),
      (
        title: 'Supabase (для сравнения)',
        small: ['${config.supabaseUrl}/auth/v1/health'],
        big: null,
        headers: {'apikey': config.supabaseAnonKey},
      ),
    ];
  }

  static Future<List<DiagResult>> run(void Function(List<DiagResult>) onProgress) async {
    final results = <DiagResult>[];
    for (final p in _platforms) {
      results.add(await _check(p.title, p.small, p.big, p.headers));
      onProgress(List.of(results));
    }
    return results;
  }

  static Future<DiagResult> _check(
    String title,
    List<String> small,
    String? big,
    Map<String, String> headers,
  ) async {
    var ok = 0;
    var total = 0;
    var totalMs = 0;
    String? error;
    for (var i = 0; i < _small; i++) {
      total++;
      final sw = Stopwatch()..start();
      try {
        await _request(small[i % small.length], headers, maxBytes: 64 * 1024);
        ok++;
        totalMs += sw.elapsedMilliseconds;
      } catch (e) {
        error = _short(e);
      }
    }
    final parts = <String>[
      'короткие запросы: $ok из $total${ok > 0 ? ', в среднем ${totalMs ~/ ok} мс' : ''}',
    ];
    var bigOk = true;
    if (big != null) {
      try {
        final bytes = await _request(big, headers, maxBytes: _bigBytes);
        bigOk = bytes >= _bigBytes;
        parts.add('загрузка: ${bytes ~/ 1024} КБ из ${_bigBytes ~/ 1024}'
            '${bigOk ? '' : ' — соединение оборвалось'}');
      } catch (e) {
        bigOk = false;
        parts.add('загрузка: ошибка (${_short(e)})');
      }
    }
    if (error != null && ok < total) parts.add('ошибка: $error');
    return DiagResult(title, ok: ok == total && bigOk, detail: parts.join('\n'));
  }

  /// Один запрос по новому соединению. Возвращает, сколько байт удалось прочитать.
  static Future<int> _request(String url, Map<String, String> headers, {required int maxBytes}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = Duration.zero;
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = false;
      request.persistentConnection = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(const Duration(seconds: 10));
      var bytes = 0;
      final done = Completer<void>();
      late final StreamSubscription<List<int>> sub;
      sub = response.listen(
        (chunk) {
          bytes += chunk.length;
          if (bytes >= maxBytes && !done.isCompleted) {
            sub.cancel();
            done.complete();
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        cancelOnError: true,
      );
      // Повисшую загрузку не считаем ошибкой — просто покажем, сколько дошло.
      await done.future.timeout(const Duration(seconds: 15), onTimeout: () => sub.cancel());
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  static String _short(Object e) {
    final text = e.toString().replaceAll('\n', ' ');
    return text.length > 100 ? '${text.substring(0, 100)}…' : text;
  }
}
