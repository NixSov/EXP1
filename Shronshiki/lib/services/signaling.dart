import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Ответ сервера на опрос комнаты.
class PollResult {
  PollResult({required this.full, required this.peers, required this.signals});

  final bool full;

  /// Все участники (включая меня): peer_id, name, muted, joined_at.
  final List<Map<String, dynamic>> peers;

  /// Новые сообщения для меня: from, payload.
  final List<({String from, Map<String, dynamic> payload})> signals;
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
  final List<Map<String, dynamic>> _outbox = [];
  Timer? _flushTimer;
  bool _flushing = false;
  bool _closed = false;

  Future<PollResult> poll({
    required String name,
    required bool muted,
    required int joinedAt,
  }) async {
    final raw = await _db.rpc('room_poll', params: {
      'p_room': roomId,
      'p_peer': peerId,
      'p_name': name,
      'p_muted': muted,
      'p_joined_at': joinedAt,
      'p_after': _lastSignalId,
    }).timeout(_timeout);
    final data = Map<String, dynamic>.from(raw as Map);
    final signals = <({String from, Map<String, dynamic> payload})>[];
    for (final item in (data['signals'] as List?) ?? const []) {
      final m = Map<String, dynamic>.from(item as Map);
      final id = (m['id'] as num).toInt();
      if (id <= _lastSignalId) continue;
      _lastSignalId = id;
      signals.add((from: m['from'] as String, payload: Map<String, dynamic>.from(m['payload'] as Map)));
    }
    return PollResult(
      full: data['full'] == true,
      peers: [for (final p in (data['peers'] as List?) ?? const []) Map<String, dynamic>.from(p as Map)],
      signals: signals,
    );
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
