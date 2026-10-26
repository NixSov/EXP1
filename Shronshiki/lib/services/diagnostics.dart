import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

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
/// и долгое Realtime-соединение с большим объёмом данных (провайдеры иногда
/// режут соединения с зарубежными облаками после первых ~16 КБ).
class Diagnostics {
  static Future<List<DiagResult>> run(void Function(List<DiagResult>) onProgress) async {
    final results = <DiagResult>[];
    void add(DiagResult r) {
      results.add(r);
      onProgress(List.of(results));
    }

    add(await _health());
    add(await _database());
    add(await _realtime());
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

  static Future<DiagResult> _realtime() async {
    const title = 'Realtime (связь в комнате)';
    const messages = 40;
    final db = AppState.instance.db;
    final channel = db.channel(
      'diag:${Random().nextInt(1 << 32)}',
      opts: const RealtimeChannelConfig(self: true),
    );
    var received = 0;
    final subscribed = Completer<String?>();
    channel.onBroadcast(event: 'diag', callback: (_) => received++).subscribe((state, error) {
      if (subscribed.isCompleted) return;
      if (state == RealtimeSubscribeStatus.subscribed) subscribed.complete(null);
      if (state == RealtimeSubscribeStatus.channelError || state == RealtimeSubscribeStatus.timedOut) {
        subscribed.complete('${state.name} ${error ?? ''}'.trim());
      }
    });
    final sw = Stopwatch()..start();
    try {
      final error = await subscribed.future.timeout(const Duration(seconds: 20));
      if (error != null) return DiagResult(title, ok: false, detail: 'не подключилось: $error');
      final connectMs = sw.elapsedMilliseconds;
      // ~40 КБ: если провайдер обрывает соединение после 16 КБ, часть сообщений не вернётся.
      final filler = base64.encode(List.filled(750, 7));
      for (var i = 0; i < messages; i++) {
        await channel.sendBroadcastMessage(event: 'diag', payload: {'i': i, 'data': filler});
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (received < messages && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final ok = received >= messages;
      return DiagResult(title,
          ok: ok,
          detail: 'подключение $connectMs мс, вернулось $received из $messages сообщений (~40 КБ)'
              '${ok ? '' : ' — соединение режется'}');
    } on TimeoutException {
      return DiagResult(title, ok: false, detail: 'нет ответа 20 секунд');
    } catch (e) {
      return DiagResult(title, ok: false, detail: _short(e));
    } finally {
      await db.removeChannel(channel);
    }
  }

  static String _short(Object e) {
    final text = e.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}
