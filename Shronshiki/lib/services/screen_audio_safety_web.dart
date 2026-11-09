import 'screen_audio_policy.dart';

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart';

/// Allow audio only from another browser tab, never an unfiltered system mix.
Future<void> validateScreenAudio(MediaStream capture) async {
  if (capture.getAudioTracks().isEmpty) return;
  final video = capture.getVideoTracks().firstOrNull;
  if (video is! MediaStreamTrackWeb) {
    throw StateError('Не удалось проверить источник звука');
  }
  final track = video.jsTrack;
  final settings = track.getSettings();
  if (settings.getProperty<JSString?>('displaySurface'.toJS)?.toDart !=
          'browser' ||
      !track.has('getCaptureHandle')) {
    throw StateError('Для звука выберите другую вкладку в Chrome или Edge');
  }
  final handle = track.callMethod<JSObject?>('getCaptureHandle'.toJS);
  if (!safeBrowserAudio(
    surface: 'browser',
    canIdentify: true,
    capturedHandle: handle?.getProperty<JSString?>('handle'.toJS)?.toDart,
  )) {
    throw StateError(
      'Звук вкладки Схронщиков не передаётся, чтобы не повторять голоса',
    );
  }
}
