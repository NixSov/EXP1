import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import 'background_call.dart';

/// Упоминание меня в чате какой-то комнаты.
class MentionNotice {
  MentionNotice({
    required this.fromName,
    required this.body,
    required this.roomName,
    required this.roomCode,
  });

  final String fromName;
  final String body;
  final String roomName;
  final String roomCode;

  factory MentionNotice.fromMap(Map<String, dynamic> m) => MentionNotice(
        fromName: m['from_name'] as String? ?? 'Кто-то',
        body: m['body'] as String? ?? '',
        roomName: m['room_name'] as String? ?? 'комната',
        roomCode: m['room_code'] as String? ?? '',
      );

  String get title => '$fromName упоминает вас в «$roomName»';
}

/// Пока приложение запущено (открыто или свёрнуто), раз в 2 минуты спрашивает
/// сервер о новых упоминаниях и показывает уведомление: системное на Android,
/// мигание на панели задач Windows и плашку внутри приложения. Реже нельзя
/// сделать незаметным, чаще — посредник на Deno не выключается и тратит лимит.
class MentionWatcher {
  MentionWatcher._();

  static const _interval = Duration(minutes: 2);

  static Timer? _timer;
  static bool _serverSupports = true;
  static bool _busy = false;

  /// Для плашки внутри приложения (MaterialApp.scaffoldMessengerKey).
  static final messengerKey = GlobalKey<ScaffoldMessengerState>();

  static void start() {
    stop();
    _serverSupports = true;
    unawaited(BackgroundCall.requestNotificationPermission());
    unawaited(check());
    _timer = Timer.periodic(_interval, (_) => unawaited(check()));
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> check() async {
    if (!_serverSupports || _busy || AppState.instance.db.auth.currentUser == null) return;
    _busy = true;
    try {
      final raw = await AppState.instance.db.rpc('my_notifications').timeout(const Duration(seconds: 15));
      for (final item in (raw as List?) ?? const []) {
        _show(MentionNotice.fromMap(Map<String, dynamic>.from(item as Map)));
      }
    } on PostgrestException catch (e) {
      // База ещё без упоминаний (не выполнена миграция mentions) — молча выключаемся.
      if (e.code == 'PGRST202') {
        _serverSupports = false;
        stop();
      }
    } catch (e) {
      debugPrint('mentions check failed: $e');
    } finally {
      _busy = false;
    }
  }

  static void _show(MentionNotice notice) {
    unawaited(BackgroundCall.showMention(
      title: notice.title,
      text: notice.body,
      roomCode: notice.roomCode,
    ));
    messengerKey.currentState?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('${notice.title}:\n${notice.body}', maxLines: 3, overflow: TextOverflow.ellipsis),
      action: notice.roomCode.isEmpty
          ? null
          : SnackBarAction(
              label: 'Открыть',
              onPressed: () => AppState.instance.pendingJoinCode.value = notice.roomCode,
            ),
    ));
  }
}
