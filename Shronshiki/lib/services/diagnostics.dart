import 'dart:async';
import 'dart:io';


import '../app_state.dart';

class DiagResult {
  DiagResult(this.title, {required this.ok, required this.detail});

  final String title;
  final bool ok;
  final String detail;

  @override
  String toString() => '${ok ? '✅' : '❌'} $title: $detail';
}

/// Проверка связи с Supabase из текущей сети: короткий запрос, база данных
/// и серия запросов, как во время звонка.
class Diagnostics {
  static Future<List<DiagResult>> run(void Function(List<DiagResult>) onProgress) async {
    final results = <DiagResult>[];
    void add(DiagResult r) {
      results.add(r);
      onProgress(List.of(results));
    }

    add(await _health());
    add(await _database());
    add(await _series());
    return results;
  }

  static Future<DiagResult> _health() async {
    const title = 'Сервер Supabase';
    final config = AppState.instance.config;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    final sw = Stopwatch()..start();
    try {
      final request = await client.getUrl(Uri.parse('${config.supabaseUrl}/auth/v1/health'));
      request.headers.set('apikey', config.supabaseAnonKey);
      final response = await request.close().timeout(const Duration(seconds: 10));
      await response.drain<void>().timeout(const Duration(seconds: 10));
      return DiagResult(title,
          ok: response.statusCode < 500, detail: 'ответ ${response.statusCode} за ${sw.elapsedMilliseconds} мс');
    } catch (e) {
      return DiagResult(title, ok: false, detail: _short(e));
    } finally {
      client.close(force: true);
    }
  }

  static Future<DiagResult> _database() async {
    const title = 'База данных';
    final sw = Stopwatch()..start();
    try {
      await AppState.instance.rooms.findByCode('AAAAAA');
      return DiagResult(title, ok: true, detail: 'запрос за ${sw.elapsedMilliseconds} мс');
    } catch (e) {
      return DiagResult(title, ok: false, detail: _short(e));
    }
  }

  /// Так приложение общается с сервером во время звонка: короткие запросы подряд.
  static Future<DiagResult> _series() async {
    const title = 'Серия запросов (как во время звонка)';
    const count = 20;
    var ok = 0;
    var totalMs = 0;
    Object? lastError;
    for (var i = 0; i < count; i++) {
      final sw = Stopwatch()..start();
      try {
        await AppState.instance.rooms.findByCode('AAAAAA');
        ok++;
        totalMs += sw.elapsedMilliseconds;
      } catch (e) {
        lastError = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final avg = ok == 0 ? 0 : totalMs ~/ ok;
    return DiagResult(title,
        ok: ok == count,
        detail: 'успешно $ok из $count, в среднем $avg мс'
            '${lastError != null ? '\nпоследняя ошибка: ${_short(lastError)}' : ''}');
  }

  static String _short(Object e) {
    final text = e.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}
