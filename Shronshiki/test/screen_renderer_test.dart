import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shronshiki/services/call_controller.dart';
import 'package:shronshiki/widgets/screen_share.dart';

class _RemoteStream extends Fake implements MediaStream {
  @override
  String get id => 'remote-screen';
  @override
  String get ownerTag => 'remote-peer';
}

class _Call extends Fake implements CallController {
  final MediaStream stream = _RemoteStream();
  @override
  ({MediaStream stream, String? trackId})? screenOf(String remoteId) =>
      (stream: stream, trackId: 'video-track');
}

void main() {
  testWidgets(
    'native screen attaches the received video without muting a remote stream',
    (tester) async {
      final calls = <MethodCall>[];
      const methods = MethodChannel('FlutterWebRTC.Method');
      const events = MethodChannel('FlutterWebRTC/Texture42');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async {
        calls.add(call);
        if (call.method == 'createVideoRenderer') return {'textureId': 42};
        return null;
      });
      messenger.setMockMethodCallHandler(events, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(methods, null);
        messenger.setMockMethodCallHandler(events, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 300,
              child: ScreenView(
                call: _Call(),
                sharer: Participant(
                  peerId: 'peer',
                  name: 'Presenter',
                  joinedAt: 1,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final attached = calls.where(
        (c) => c.method == 'videoRendererSetSrcObject',
      );
      expect(attached, isNotEmpty);
      expect((attached.first.arguments as Map)['trackId'], 'video-track');
      expect(
        calls.where((c) => c.method == 'mediaStreamTrackSetEnable'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
