import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/services/screen_audio_policy.dart';

void main() {
  test('screen audio rejects system mixes and Shronshiki tabs', () {
    expect(
      safeBrowserAudio(
        surface: 'monitor',
        canIdentify: true,
        capturedHandle: null,
      ),
      isFalse,
    );
    expect(
      safeBrowserAudio(
        surface: 'window',
        canIdentify: true,
        capturedHandle: null,
      ),
      isFalse,
    );
    expect(
      safeBrowserAudio(
        surface: 'browser',
        canIdentify: false,
        capturedHandle: null,
      ),
      isFalse,
    );
    expect(
      safeBrowserAudio(
        surface: 'browser',
        canIdentify: true,
        capturedHandle: 'shronshiki',
      ),
      isFalse,
    );
    expect(
      safeBrowserAudio(
        surface: 'browser',
        canIdentify: true,
        capturedHandle: null,
      ),
      isTrue,
    );
  });
}
