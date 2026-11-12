import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _AudioTrack extends Fake implements MediaStreamTrack {
  _AudioTrack(this.id);
  @override
  final String id;
  @override
  String get kind => 'audio';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native volume preserves 250% gain and separate track identities', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('FlutterWebRTC.Method');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async { if (call.method == 'setVolume') calls.add(call); });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await Helper.setVolume(0.35, _AudioTrack('voice'));
    await Helper.setVolume(2.5, _AudioTrack('screen'));
    expect(calls.map((c) => c.method), ['setVolume', 'setVolume']);
    expect(calls[0].arguments['trackId'], 'voice');
    expect(calls[0].arguments['volume'], 0.35);
    expect(calls[1].arguments['trackId'], 'screen');
    expect(calls[1].arguments['volume'], 2.5);
  });
}


