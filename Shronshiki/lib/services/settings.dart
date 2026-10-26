import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Пользовательские настройки звука.
class AudioSettings extends ChangeNotifier {
  AudioSettings._(this._prefs);

  static const _kNoiseSuppression = 'audio_noise_suppression';
  static const _kSpeaker = 'audio_speaker';

  final SharedPreferences _prefs;

  static Future<AudioSettings> load() async =>
      AudioSettings._(await SharedPreferences.getInstance());

  bool get noiseSuppression => _prefs.getBool(_kNoiseSuppression) ?? true;
  set noiseSuppression(bool value) {
    _prefs.setBool(_kNoiseSuppression, value);
    notifyListeners();
  }

  /// Громкая связь по умолчанию при входе в комнату.
  bool get speakerByDefault => _prefs.getBool(_kSpeaker) ?? true;
  set speakerByDefault(bool value) {
    _prefs.setBool(_kSpeaker, value);
    notifyListeners();
  }

  /// Ограничения getUserMedia для микрофона.
  ///
  /// Стандартные ключи понимают Windows/web, а Android-реализация
  /// flutter_webrtc читает только `mandatory`/`optional` со старыми именами goog*.
  Map<String, dynamic> audioConstraints() {
    final ns = noiseSuppression;
    return {
      'echoCancellation': true,
      'noiseSuppression': ns,
      'autoGainControl': true,
      'mandatory': {
        'googEchoCancellation': 'true',
        'googNoiseSuppression': '$ns',
        'googAutoGainControl': 'true',
        'googHighpassFilter': 'true',
      },
      'optional': [
        {'echoCancellation': 'true'},
        {'noiseSuppression': '$ns'},
        {'autoGainControl': 'true'},
      ],
    };
  }
}
