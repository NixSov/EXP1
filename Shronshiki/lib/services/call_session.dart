import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'background_call.dart';
import 'call_controller.dart';
import 'rooms.dart';

/// Текущий звонок приложения. Живёт отдельно от экрана комнаты, поэтому можно
/// уйти в настройки или к списку комнат и не выйти из звонка.
class CallSession {
  CallSession._();

  static final ValueNotifier<CallController?> current = ValueNotifier(null);

  static CallStatus? _lastStatus;
  static bool? _lastMuted;

  static void init() {
    BackgroundCall.onHangUp = () => leave();
    BackgroundCall.onToggleMute = () => current.value?.toggleMute();
  }

  /// Входит в комнату (если уже в ней — возвращает текущий звонок).
  static CallController join(Room room, String displayName) {
    final active = current.value;
    if (active != null && active.room.id == room.id && active.isActive) return active;
    if (active != null) leave();

    final app = AppState.instance;
    final call = CallController(
      room: room,
      displayName: displayName,
      config: app.config,
      settings: app.settings,
    );
    _lastStatus = null;
    _lastMuted = null;
    call.addListener(() => _onCallChanged(call));
    current.value = call;
    call.start();
    return call;
  }

  static void _onCallChanged(CallController call) {
    if (current.value != call) return;
    final status = call.status;
    if (status != _lastStatus) {
      _lastStatus = status;
      if (status == CallStatus.inRoom) {
        _lastMuted = call.muted;
        BackgroundCall.start(roomName: call.room.name, muted: call.muted);
      } else if (status != CallStatus.connecting) {
        BackgroundCall.stop();
      }
    } else if (status == CallStatus.inRoom && call.muted != _lastMuted) {
      _lastMuted = call.muted;
      BackgroundCall.update(muted: call.muted);
    }
  }

  /// Выход из комнаты.
  static Future<void> leave() async {
    final call = current.value;
    if (call == null) return;
    current.value = null;
    await BackgroundCall.stop();
    await call.hangUp();
    call.dispose();
  }

  /// Убирает звонок, который закончился ошибкой или «комната заполнена».
  static void dismissIfFinished() {
    final call = current.value;
    if (call != null && !call.isActive) leave();
  }
}
