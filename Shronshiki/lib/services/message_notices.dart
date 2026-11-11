import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import 'background_call.dart';

/// Local delivery while running; FCM handles Android delivery while closed.
class MessageNotices {
  static Timer? _timer;
  static String? _user;
  static bool _busy = false;
  static int _generation = 0;
  static String? activeChat;
  static final pushReady = ValueNotifier(false);

  static Future<void> start() async {
    stop();
    final app = AppState.instance;
    _user = app.db.auth.currentUser?.id;
    final generation = _generation;
    app.settings.addListener(_settingsChanged);
    BackgroundCall.onPushToken = (token) => unawaited(_register(token));
    await _configure();
    if (generation != _generation) return;
    unawaited(check());
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(check()),
    );
  }

  static void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _user = null;
    AppState.instance.settings.removeListener(_settingsChanged);
    BackgroundCall.onPushToken = null;
    unawaited(BackgroundCall.configureMessages(enabled: false, user: null));
  }

  static void _settingsChanged() => unawaited(_configure());
  static Future<void> _register(String token) async {
    final user = _user;
    if (user == null) return;
    try {
      await AppState.instance.db
          .rpc(
            'register_push',
            params: {
              'p_token': token,
              'p_enabled': AppState.instance.settings.messageNotifications,
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('push register failed: $e');
    }
  }

  static Future<void> _configure() async {
    final app = AppState.instance;
    if (app.settings.messageNotifications) {
      await BackgroundCall.requestNotificationPermission();
    }
    final token = await BackgroundCall.configureMessages(
      enabled: app.settings.messageNotifications,
      user: _user,
    );
    pushReady.value = token != null;
    if (token != null) await _register(token);
  }

  static Future<void> check() async {
    if (_busy || _user == null) return;
    _busy = true;
    final user = _user;
    final generation = _generation;
    try {
      final app = AppState.instance;
      final prefs = await SharedPreferences.getInstance();
      final key = 'message_notice_cursor_$user';
      var cursor = prefs.getInt(key);
      if (cursor == null || !app.settings.messageNotifications) {
        final newest = await app.db
            .rpc('message_notice_cursor', get: true, params: const {})
            .timeout(const Duration(seconds: 15));
        if (generation == _generation) {
          await prefs.setInt(key, (newest as num).toInt());
        }
        return;
      }
      final raw = await app.db
          .rpc('message_notifications', get: true, params: {'p_after': cursor})
          .timeout(const Duration(seconds: 20));
      for (final item in raw as List) {
        if (generation != _generation) return;
        final notice = Map<String, dynamic>.from(item as Map);
        if (app.settings.messageNotifications &&
            (notice['chat_id'] == null || notice['chat_id'] != activeChat)) {
          await BackgroundCall.showMessage({...notice, 'user': user});
        }
        cursor = (notice['id'] as num).toInt();
        await prefs.setInt(key, cursor);
      }
    } catch (e) {
      debugPrint('message notices failed: $e');
    } finally {
      _busy = false;
    }
  }
}
