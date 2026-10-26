import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Сообщение чата комнаты.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.peerId,
    required this.name,
    required this.body,
    required this.at,
  });

  final int id;
  final String peerId;
  final String name;
  final String body;
  final DateTime at;

  factory ChatMessage.fromMap(Map<String, dynamic> m) => ChatMessage(
        id: (m['id'] as num).toInt(),
        peerId: m['peer_id'] as String? ?? '',
        name: m['name'] as String? ?? 'Участник',
        body: m['body'] as String? ?? '',
        at: DateTime.fromMillisecondsSinceEpoch((m['at'] as num?)?.toInt() ?? 0),
      );
}

/// Ответ сервера на опрос комнаты.
class PollResult {
  PollResult({
    required this.full,
    required this.peers,
    required this.signals,
    this.messages = const [],
  });

  final bool full;

  /// Все участники (включая меня): peer_id, name, muted, joined_at.
  final List<Map<String, dynamic>> peers;

  /// Новые сообщения для меня: from, payload.
  final List<({String from, Map<String, dynamic> payload})> signals;

  /// Новые сообщения чата (при входе — последние 100).
  final List<ChatMessage> messages;
}

/// Сигналинг через короткие HTTP-запросы к функциям базы (room_poll / room_send /
/// room_leave). Используется вместо Realtime (WebSocket), который часть
/// провайдеров в России не пропускает.
class RoomSignaling {
  RoomSignaling(this._db, {required this.roomId, required this.peerId});

  final SupabaseClient _db;
  final String roomId;
  final String peerId;

  static const _timeout = Duration(seconds: 8);

  int _lastSignalId = 0;
  int _lastMessageId = 0;

  /// false — на сервере старая версия базы без чата (не выполнена миграция room_chat).
  bool chatSupported = true;
  final List<Map<String, dynamic>> _outbox = [];
  Timer? _flushTimer;
  bool _flushing = false;
  bool _closed = false;

  Future<PollResult> poll({
    required String name,
    required bool muted,
    required int joinedAt,
  }) async {
    final params = {
      'p_room': roomId,
      'p_peer': peerId,
      'p_name': name,
      'p_muted': muted,
      'p_joined_at': joinedAt,
      'p_after': _lastSignalId,
      if (chatSupported) 'p_after_msg': _lastMessageId,
    };
    Object? raw;
    try {
      raw = await _db.rpc('room_poll', params: params).timeout(_timeout);
    } on PostgrestException catch (e) {
      // База ещё без чата: функция не знает p_after_msg. Работаем без чата.
      if (!chatSupported || e.code != 'PGRST202') rethrow;
      chatSupported = false;
      params.remove('p_after_msg');
      raw = await _db.rpc('room_poll', params: params).timeout(_timeout);
    }
    final data = Map<String, dynamic>.from(raw as Map);
    final signals = <({String from, Map<String, dynamic> payload})>[];
    for (final item in (data['signals'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(item as Map);
      final id = (m['id'] as num).toInt();
      if (id <= _lastSignalId) continue;
      _lastSignalId = id;
      signals.add((from: m['from'] as String, payload: Map<String, dynamic>.from(m['payload'] as Map)));
    }
    final messages = <ChatMessage>[];
    for (final item in (data['messages'] as List?) ?? const []) {
      final message = ChatMessage.fromMap(Map<String, dynamic>.from(item as Map));
      if (message.id <= _lastMessageId) continue;
      _lastMessageId = message.id;
      messages.add(message);
    }
    return PollResult(
      full: data['full'] == true,
      messages: messages,
      peers: [for (final p in (data['peers'] as List?) ?? const []) Map<String, dynamic>.from(p as Map)],
      signals: signals,
    );
  }

  /// Отправляет сообщение в чат комнаты.
  Future<void> sendChat(String body) async {
    await _db.rpc('room_chat_send', params: {
      'p_room': roomId,
      'p_peer': peerId,
      'p_body': body,
    }).timeout(_timeout);
  }

  /// Кого можно упомянуть: бывавшие в комнате (сервер с миграцией mentions).
  /// null — сервер такого не умеет.
  Future<List<({String name, bool inRoom})>?> memberNames() async {
    try {
      final rows = await _db.rpc('room_member_names', params: {'p_room': roomId}).timeout(_timeout) as List;
      return [
        for (final r in rows)
          (name: (r as Map)['name'] as String, inRoom: r['in_room'] == true),
      ];
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202') return null;
      rethrow;
    }
  }

  /// Кладёт сообщение в очередь. ICE-кандидаты идут пачками — отправляем
  /// их одним запросом через небольшую паузу.
  void send(String to, Map<String, dynamic> payload) {
    if (_closed) return;
    _outbox.add({'to': to, 'payload': payload});
    _flushTimer ??= Timer(const Duration(milliseconds: 80), flush);
  }

  Future<void> flush() async {
    _flushTimer = null;
    if (_flushing || _outbox.isEmpty) return;
    _flushing = true;
    final batch = List.of(_outbox.take(100));
    try {
      await _db.rpc('room_send', params: {
        'p_room': roomId,
        'p_from': peerId,
        'p_messages': batch,
      }).timeout(_timeout);
      _outbox.removeRange(0, batch.length);
    } catch (e) {
      debugPrint('signal send failed, will retry: $e');
      if (!_closed) _flushTimer ??= Timer(const Duration(seconds: 1), flush);
    } finally {
      _flushing = false;
    }
    if (_outbox.isNotEmpty && !_closed) _flushTimer ??= Timer(Duration.zero, flush);
  }

  /// Выход из комнаты: досылаем очередь (например, «bye») и удаляемся с сервера.
  Future<void> leave() async {
    try {
      await flush().timeout(const Duration(seconds: 2));
    } catch (_) {}
    _closed = true;
    _flushTimer?.cancel();
    _outbox.clear();
    try {
      await _db.rpc('room_leave', params: {'p_room': roomId, 'p_peer': peerId})
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('room_leave failed: $e');
    }
  }

  void close() {
    _closed = true;
    _flushTimer?.cancel();
  }
}
