import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';

/// Счётчик расхода бесплатных лимитов: время в звонках, трафик через свой TURN
/// и запросы через посредника. Раз в минуту прибавка уходит на сервер
/// (report_usage, миграция usage), там она складывается со всеми участниками.
class UsageMeter {
  UsageMeter._();

  static int _ms = 0;
  static int _turnMs = 0;
  static int _proxyMs = 0;
  static int _turnBytes = 0;
  static int _proxyRequests = 0;
  static Timer? _timer;
  static bool _sending = false;

  /// false — база без миграции usage: считать незачем.
  static bool _serverSupports = true;

  static void addTurnBytes(int bytes) {
    _turnBytes += bytes;
    _ensureTimer();
  }

  static void countProxyRequest() {
    _proxyRequests++;
    _ensureTimer();
  }

  /// [ms] звонка, в котором кто-то ещё на связи; [turn] — через свой TURN.
  static void addCallTime(int ms, {required bool turn}) {
    final app = AppState.instance;
    final proxy = app.supabaseReady && app.route.usingProxy;
    _ms += ms;
    if (turn) _turnMs += ms;
    if (proxy) _proxyMs += ms;
    _ensureTimer();
  }

  static void _ensureTimer() {
    if (!_serverSupports) return;
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) => unawaited(flush()));
  }

  /// Отправляет накопленное. Не дошло — останется до следующего раза.
  static Future<void> flush() async {
    if (_sending || !_serverSupports || !AppState.instance.supabaseReady) return;
    // Сервер принимает не больше часа и 2 ГБ за раз; остаток уйдёт следующим.
    final seconds = (_ms ~/ 1000).clamp(0, 3600);
    final turnSeconds = (_turnMs ~/ 1000).clamp(0, seconds);
    final proxySeconds = (_proxyMs ~/ 1000).clamp(0, seconds);
    final turnBytes = _turnBytes.clamp(0, 2000000000);
    final proxyRequests = _proxyRequests.clamp(0, 5000);
    if (seconds == 0 && turnBytes == 0 && proxyRequests == 0) return;
    final db = Supabase.instance.client;
    if (db.auth.currentUser == null) return;
    _sending = true;
    try {
      await db.rpc('report_usage', params: {
        'p_seconds': seconds,
        'p_turn_seconds': turnSeconds,
        'p_proxy_seconds': proxySeconds,
        'p_turn_bytes': turnBytes,
        'p_proxy_requests': proxyRequests,
      }).timeout(const Duration(seconds: 10));
      _ms -= seconds * 1000;
      _turnMs -= turnSeconds * 1000;
      _proxyMs -= proxySeconds * 1000;
      _turnBytes -= turnBytes;
      _proxyRequests -= proxyRequests;
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') {
        _serverSupports = false;
        _timer?.cancel();
        _timer = null;
      } else {
        debugPrint('report_usage failed: ${e.message}');
      }
    } catch (e) {
      debugPrint('report_usage failed: $e');
    } finally {
      _sending = false;
    }
  }
}
