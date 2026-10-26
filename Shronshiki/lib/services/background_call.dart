import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Связь с нативной частью звонка.
///
/// Android (CallService.kt): уведомление, работа в фоне, кнопка наушников.
/// Windows (flutter_window.cpp): медиаклавиша Play/Pause и кнопка наушников
/// включают и выключают микрофон, даже когда окно свёрнуто.
class BackgroundCall {
  BackgroundCall._();

  static const _channel = MethodChannel('shronshiki/call');

  /// Фоновый сервис, уведомление, батарея — только Android.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Кнопка наушников / медиаклавиша управляет микрофоном.
  static bool get hasHeadsetButton => !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  static bool get _channelAvailable => hasHeadsetButton;

  static VoidCallback? onHangUp;
  static VoidCallback? onToggleMute;

  /// Пока открыта «Проверка кнопки наушников», нажатия идут сюда, а не в микрофон.
  static void Function(String key)? onMediaKeyTest;

  static void init() {
    if (!_channelAvailable) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onMediaKey') {
        final test = onMediaKeyTest;
        if (test != null) {
          test('${call.arguments}');
        } else {
          onToggleMute?.call();
        }
        return;
      }
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
    if (!_channelAvailable) return;
    try {
      if (supported) await _channel.invokeMethod('requestNotificationPermission');
      await _channel.invokeMethod('start', {'title': 'Shronshiki: $roomName', 'muted': muted});
    } catch (e) {
      debugPrint('call service start failed: $e');
    }
  }

  static Future<void> update({required bool muted}) async {
    if (!_channelAvailable) return;
    try {
      await _channel.invokeMethod('update', {'muted': muted});
    } catch (e) {
      debugPrint('call service update failed: $e');
    }
  }

  static Future<void> stop() async {
    if (!_channelAvailable) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('call service stop failed: $e');
    }
  }

  static Future<void> startButtonTest(void Function(String key) onKey) async {
    onMediaKeyTest = onKey;
    if (!_channelAvailable) return;
    try {
      await _channel.invokeMethod('startButtonTest');
    } catch (e) {
      debugPrint('button test start failed: $e');
    }
  }

  static Future<void> stopButtonTest() async {
    onMediaKeyTest = null;
    if (!_channelAvailable) return;
    try {
      await _channel.invokeMethod('stopButtonTest');
    } catch (_) {}
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
