import 'package:supabase_flutter/supabase_flutter.dart';

import 'chats.dart';

/// Комната в админ-панели.
class AdminRoom {
  AdminRoom(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = m['name'] as String,
        code = m['code'] as String,
        owner = m['owner'] as String? ?? '—',
        ownerEmail = m['owner_email'] as String?,
        online = (m['online'] as num?)?.toInt() ?? 0;

  final String id;
  final String name;
  final String code;
  final String owner;
  final String? ownerEmail;
  final int online;
}

/// Чат в админ-панели.
class AdminChat {
  AdminChat(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = m['name'] as String,
        code = m['code'] as String,
        owner = m['owner'] as String? ?? '—',
        members = (m['members'] as num?)?.toInt() ?? 0,
        messages = (m['messages'] as num?)?.toInt() ?? 0;

  final String id;
  final String name;
  final String code;
  final String owner;
  final int members;
  final int messages;
}

/// Аккаунт в админ-панели.
class AdminUser {
  AdminUser(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = m['name'] as String? ?? 'Без имени',
        email = m['email'] as String?,
        created = _date(m['created']),
        lastSignIn = _date(m['last_sign_in']),
        guest = m['guest'] == true,
        admin = m['admin'] == true,
        rooms = (m['rooms'] as num?)?.toInt() ?? 0;

  final String id;
  final String name;
  final String? email;
  final DateTime? created;
  final DateTime? lastSignIn;
  final bool guest;
  final bool admin;
  final int rooms;

  static DateTime? _date(Object? ms) => ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;
}

/// Запросы админ-панели (миграция admin). Сервер сам проверяет, что вызывает
/// администратор; у остальных любой запрос отклоняется.
class AdminRepository {
  AdminRepository(this._db);

  final SupabaseClient _db;
  static const _timeout = Duration(seconds: 20);

  Future<Object?> _call(String fn, [Map<String, dynamic>? params]) =>
      _db.rpc(fn, params: params ?? const {}).timeout(_timeout);

  Future<List<Map<String, dynamic>>> _list(String fn, [Map<String, dynamic>? params]) async =>
      [for (final m in await _call(fn, params) as List) Map<String, dynamic>.from(m as Map)];

  /// Администратор ли текущий пользователь. Сервер без миграции — нет.
  Future<bool> isAdmin() async {
    try {
      return await _call('is_admin') == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<AdminRoom>> rooms() async => [for (final m in await _list('admin_rooms')) AdminRoom(m)];

  /// [code]: null — не менять, '' — новый случайный.
  Future<void> updateRoom(String id, {String? name, String? code}) =>
      _call('admin_room_update', {'p_room': id, 'p_name': name, 'p_code': code});

  Future<void> deleteRoom(String id) => _call('admin_room_delete', {'p_room': id});

  Future<List<AdminChat>> chats() async => [for (final m in await _list('admin_chats')) AdminChat(m)];

  Future<void> updateChat(String id, {String? name, String? code}) =>
      _call('admin_chat_update', {'p_chat': id, 'p_name': name, 'p_code': code});

  Future<void> deleteChat(String id) => _call('admin_chat_delete', {'p_chat': id});

  Future<List<PersistentMessage>> chatMessages(String id, {int? before}) async => [
        for (final m in await _list('admin_chat_messages', {'p_chat': id, 'p_before': before}))
          PersistentMessage.fromMap(m),
      ];

  Future<void> deleteMessage(int id) => _call('admin_chat_message_delete', {'p_message': id});

  Future<List<AdminUser>> users({required bool guests}) async =>
      [for (final m in await _list('admin_users', {'p_guests': guests})) AdminUser(m)];

  Future<void> renameUser(String id, String name) => _call('admin_user_rename', {'p_user': id, 'p_name': name});

  Future<void> setPassword(String id, String password) =>
      _call('admin_user_set_password', {'p_user': id, 'p_password': password});

  Future<void> deleteUser(String id) => _call('admin_user_delete', {'p_user': id});

  Future<void> setAdmin(String id, bool admin) => _call('admin_set_admin', {'p_user': id, 'p_admin': admin});

  /// Удаляет гостей, не заходивших дольше [days] дней; возвращает, сколько.
  Future<int> deleteOldGuests(int days) async =>
      ((await _call('admin_delete_old_guests', {'p_days': days})) as num?)?.toInt() ?? 0;
}
