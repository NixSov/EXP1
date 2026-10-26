import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Связь с нативным CallService на Android: уведомление звонка, работа в фоне,
/// кнопка наушников. На других платформах ничего не делает.
class BackgroundCall {
  BackgroundCall._();

  static const _channel = MethodChannel('shronshiki/call');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static VoidCallback? onHangUp;
  static VoidCallback? onToggleMute;

  static void init() {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onAction') return;
      switch (call.arguments) {
        case 'hangup':
          onHangUp?.call();
        case 'toggleMute':
          onToggleMute?.call();
      }
    });
  }

  static Future<void> start({required String roomName, required bool muted}) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('requestNotificationPermission');
      await _channel.invokeMethod('start', {'title': 'Shronshiki: $roomName', 'muted': muted});
    } catch (e) {
      debugPrint('call service start failed: $e');
    }
  }

  static Future<void> update({required bool muted}) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('update', {'muted': muted});
    } catch (e) {
      debugPrint('call service update failed: $e');
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('call service stop failed: $e');
    }
  }

  static Future<void> moveToBack() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('moveToBack');
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('battery optimization request failed: $e');
    }
  }
}
