import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Foreground service на Android: держит процесс живым, пока идёт звонок,
/// и показывает уведомление с кнопкой «Отключиться».
class BackgroundCall {
  BackgroundCall._();

  static const _hangUpButton = 'hangup';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static VoidCallback? _onHangUp;

  static void init() {
    if (!supported) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'shronshiki_call',
        channelName: 'Голосовой звонок',
        channelDescription: 'Уведомление, пока вы в голосовой комнате',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        stopWithTask: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  static void _onData(Object data) {
    if (data == _hangUpButton) _onHangUp?.call();
  }

  static Future<void> start({required String roomName, required VoidCallback onHangUp}) async {
    if (!supported) return;
    _onHangUp = onHangUp;
    try {
      final permission = await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final title = 'Shronshiki: $roomName';
      const text = 'Вы в голосовой комнате';
      const buttons = [NotificationButton(id: _hangUpButton, text: 'Отключиться')];
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
          notificationButtons: buttons,
        );
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 4242,
          serviceTypes: const [ForegroundServiceTypes.microphone],
          notificationTitle: title,
          notificationText: text,
          notificationButtons: buttons,
          callback: startCallTask,
        );
      }
    } catch (e) {
      debugPrint('foreground service start failed: $e');
    }
  }

  static Future<void> stop() async {
    _onHangUp = null;
    if (!supported) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('foreground service stop failed: $e');
    }
  }
}

@pragma('vm:entry-point')
void startCallTask() {
  FlutterForegroundTask.setTaskHandler(_CallTaskHandler());
}

/// Обработчик в отдельном изоляте сервиса. Сам звук работает в основном
/// изоляте приложения — сервис лишь не даёт системе его остановить.
class _CallTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    FlutterForegroundTask.sendDataToMain(id);
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}
