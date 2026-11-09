import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/services/chats.dart';
import 'package:shronshiki/services/signaling.dart';
import 'package:shronshiki/widgets/chat_bubble.dart';

void main() {
  const metadata = {'name': 'photo.png', 'mime': 'image/png', 'size': 1024};
  final raw = {
    'id': 7,
    'peer_id': 'peer0001',
    'user_id': 'u',
    'name': 'A',
    'body': 'photo.png',
    'at': 0,
    'attachment': metadata,
  };
  test('both chat models retain private attachment metadata', () {
    expect(ChatMessage.fromMap(raw).attachment, metadata);
    expect(PersistentMessage.fromMap(raw).attachment, metadata);
    expect(
      ChatMessage.fromMap({...raw, 'attachment': null}).attachment,
      isNull,
    );
  });
  testWidgets(
    'attachments expose download without fetching private bytes at build',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatBubble(
              name: 'A',
              body: 'photo.png',
              at: DateTime(2026),
              mine: false,
              showName: true,
              attachment: metadata,
              messageId: 7,
              roomFile: true,
            ),
          ),
        ),
      );
      expect(find.text('Сохранить файл'), findsOneWidget);
      expect(find.text('photo.png · 1 КБ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
