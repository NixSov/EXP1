import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Постоянный чат по ключу (миграция chats): переписка не стирается.
class PersistentChat {
  PersistentChat({
    required this.id,
    required this.code,
    required this.name,
    required this.members,
    required this.unread,
    this.lastName,
    this.lastBody,
  });

  final String id;
  final String code;
  final String name;
  final int members;
  final int unread;
  final String? lastName;
  final String? lastBody;

  factory PersistentChat.fromMap(Map<String, dynamic> m) {
    final last = m['last'] as Map?;
    return PersistentChat(
      id: m['id'] as String,
      code: m['code'] as String,
      name: m['name'] as String,
      members: (m['members'] as num?)?.toInt() ?? 1,
      unread: (m['unread'] as num?)?.toInt() ?? 0,
      lastName: last?['name'] as String?,
      lastBody: last?['body'] as String?,
    );
  }

  String get inviteText => 'Заходи в чат «$name» в Shronshiki.\n'
      'Ключ чата: $code\n'
      '(Главный экран → «Вход в чат»)';
}

/// Сообщение постоянного чата.
class PersistentMessage {
  PersistentMessage({
    required this.id,
    required this.userId,
    required this.name,
    required this.body,
    required this.at,
  });

  final int id;
  final String? userId;
  final String name;
  final String body;
  final DateTime at;

  factory PersistentMessage.fromMap(Map<String, dynamic> m) => PersistentMessage(
        id: (m['id'] as num).toInt(),
        userId: m['user_id'] as String?,
        name: m['name'] as String? ?? 'Участник',
        body: m['body'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
      );
}

class ChatsRepository {
  ChatsRepository(this._db);

  final SupabaseClient _db;
  static const _timeout = Duration(seconds: 15);

  Future<List<PersistentChat>> myChats() async {
    final raw = await _db.rpc('my_chats').timeout(_timeout);
    return [for (final m in raw as List) PersistentChat.fromMap(Map<String, dynamic>.from(m as Map))];
  }

  Future<PersistentChat> create(String name) async {
    final raw = await _db.rpc('create_chat', params: {'p_name': name}).timeout(_timeout);
    return PersistentChat.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  /// null — чата с таким ключом нет.
  Future<PersistentChat?> join(String code) async {
    final raw = await _db.rpc('join_chat', params: {'p_code': code}).timeout(_timeout);
    return raw == null ? null : PersistentChat.fromMap(Map<String, dynamic>.from(raw as Map));
  }

  /// Новые сообщения после [after] или, с [before], более старые.
  Future<List<PersistentMessage>> messages(String chatId, {int after = 0, int? before}) async {
    final raw = await _db.rpc('chat_poll', params: {
      'p_chat': chatId,
      'p_after': after,
      'p_before': ?before,
    }).timeout(_timeout);
    return [for (final m in raw as List) PersistentMessage.fromMap(Map<String, dynamic>.from(m as Map))];
  }

  Future<void> send(String chatId, String body) async {
    await _db.rpc('chat_send', params: {'p_chat': chatId, 'p_body': body}).timeout(_timeout);
  }

  Future<void> leave(String chatId) async {
    await _db.rpc('leave_chat', params: {'p_chat': chatId}).timeout(_timeout);
  }
}
