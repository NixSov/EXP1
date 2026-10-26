import 'package:supabase_flutter/supabase_flutter.dart';

class Room {
  Room({
    required this.id,
    required this.name,
    required this.code,
    required this.maxParticipants,
    this.ownerName,
  });

  final String id;
  final String name;
  final String code;
  final int maxParticipants;
  final String? ownerName;

  factory Room.fromMap(Map<String, dynamic> m) => Room(
        id: m['id'] as String,
        name: m['name'] as String,
        code: m['code'] as String,
        maxParticipants: (m['max_participants'] as num?)?.toInt() ?? 4,
        ownerName: m['owner_name'] as String?,
      );

  String get inviteLink => 'shronshiki://join/$code';

  String get inviteText =>
      'Заходи в голосовую комнату «$name» в Shronshiki.\nКод: $code\n$inviteLink';
}

/// Работа с таблицей комнат.
class RoomsRepository {
  RoomsRepository(this._db);

  final SupabaseClient _db;

  /// На медленном соединении запрос не должен висеть бесконечно.
  static const _timeout = Duration(seconds: 20);

  static const codeLength = 6;

  /// Приводит введённый код или ссылку к виду ABC234.
  static String? normalizeCode(String input) {
    var text = input.trim().toUpperCase();
    final match = RegExp(r'JOIN/([A-Z0-9]+)').firstMatch(text);
    if (match != null) text = match.group(1)!;
    text = text.replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return text.length == codeLength ? text : null;
  }

  Future<List<Room>> myRooms() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    final rows = await _db
        .from('rooms')
        .select('id, name, code, max_participants')
        .eq('owner_id', uid)
        .order('created_at', ascending: false)
        .timeout(_timeout);
    return rows.map(Room.fromMap).toList();
  }

  Future<Room> create(String name) async {
    final row = await _db.rpc('create_room', params: {'p_name': name.trim()}).timeout(_timeout);
    return Room.fromMap(Map<String, dynamic>.from(row as Map));
  }

  Future<void> rename(String id, String name) =>
      _db.from('rooms').update({'name': name.trim()}).eq('id', id);

  Future<void> delete(String id) => _db.from('rooms').delete().eq('id', id);

  Future<Room?> findByCode(String code) async {
    final rows = await _db.rpc('find_room', params: {'p_code': code}).timeout(_timeout) as List;
    if (rows.isEmpty) return null;
    return Room.fromMap(Map<String, dynamic>.from(rows.first as Map));
  }
}
