import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shronshiki/screens/room_screen.dart';
import 'package:shronshiki/services/call_controller.dart';
import 'package:shronshiki/services/rooms.dart';

class _Call extends Fake implements CallController {
  _Call({this.presenting = false});
  final bool presenting;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  @override
  Room get room =>
      Room(id: 'room', name: 'Комната', code: '猫 №1', maxParticipants: 4);
  @override
  CallStatus get status => CallStatus.inRoom;
  @override
  bool get isActive => true;
  @override
  bool get serverLost => false;
  @override
  bool get screenHidden => false;
  @override
  bool get sharingScreen => false;
  @override
  bool get muted => false;
  @override
  bool get speakerOn => false;
  @override
  bool get canSwitchSpeaker => false;
  @override
  int get unreadChat => 0;
  @override
  String? get outputId => null;
  @override
  List<AudioDevice> get outputs => [];
  @override
  List<Participant> get participants => [
    Participant(peerId: 'me', name: 'AdmiNix', joinedAt: 1, isLocal: true),
    Participant(peerId: 'other', name: 'Друг', joinedAt: 2)
      ..sharingScreen = presenting,
  ];
  @override
  Participant? get screenSharer => presenting ? participants.last : null;
  @override
  ({MediaStream stream, String? trackId})? screenOf(String remoteId) => null;
}

void main() {
  testWidgets(
    'desktop cards and controls stay compact, including connecting peers',
    (tester) async {
      tester.view.physicalSize = const Size(1333, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: RoomScreen(call: _Call())));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(Card).first).width, lessThan(200));
      final mic = tester.widget<Icon>(find.byIcon(Icons.mic).first);
      expect(mic.size, 20);
    },
  );

  testWidgets('pin hides participants and controls; Escape restores the call', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1333, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const methods = MethodChannel('FlutterWebRTC.Method');
    const events = MethodChannel('FlutterWebRTC/Texture42');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      methods,
      (call) async =>
          call.method == 'createVideoRenderer' ? {'textureId': 42} : null,
    );
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    await tester.pumpWidget(
      MaterialApp(home: RoomScreen(call: _Call(presenting: true))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Закрепить трансляцию'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(CircleAvatar), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
