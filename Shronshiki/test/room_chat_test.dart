import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shronshiki/config.dart';
import 'package:shronshiki/services/call_controller.dart';
import 'package:shronshiki/services/rooms.dart';
import 'package:shronshiki/services/settings.dart';
import 'package:shronshiki/services/signaling.dart';
import 'package:shronshiki/widgets/room_chat_sheet.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('чат комнаты показывает сообщения и сбрасывает непрочитанные', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AudioSettings.load();
    final call = CallController(
      room: Room(id: 'r', name: 'Комната', code: 'ABC234', maxParticipants: 4),
      displayName: 'Я',
      config: AppConfig(
        supabaseUrl: 'https://example.supabase.co',
        supabaseAnonKey: 'key',
        turnUrls: const [],
        turnUsername: '',
        turnCredential: '',
      ),
      settings: settings,
      client: SupabaseClient('https://example.supabase.co', 'key',
          authOptions: const AuthClientOptions(autoRefreshToken: false)),
    )..status = CallStatus.inRoom;
    call.chat.addAll([
      ChatMessage(id: 1, peerId: 'other', name: 'Боря', body: 'Привет! 👋', at: DateTime(2026, 10, 26, 19, 5)),
      ChatMessage(id: 2, peerId: 'other', name: 'Боря', body: 'Слышно?', at: DateTime(2026, 10, 26, 19, 6)),
      ChatMessage(id: 3, peerId: call.peerId, name: 'Я', body: 'Да, отлично ' * 20, at: DateTime(2026, 10, 26, 19, 7)),
    ]);
    call.unreadChat = 2;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showRoomChat(context, call),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Чат комнаты'), findsOneWidget);
    expect(find.text('Привет! 👋'), findsOneWidget);
    expect(find.text('Боря'), findsOneWidget, reason: 'имя показывается один раз для подряд идущих');
    expect(call.unreadChat, 0);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Чат комнаты'))).pop();
    await tester.pumpAndSettle();
  });
}
