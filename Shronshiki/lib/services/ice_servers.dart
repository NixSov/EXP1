import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// TURN-сервер из таблицы ice_servers в Supabase.
class ServerTurn {
  const ServerTurn({required this.name, required this.urls, required this.username, required this.credential});

  final String name;
  final List<String> urls;
  final String username;
  final String credential;

  Map<String, dynamic> toIce() => {'urls': urls, 'username': username, 'credential': credential};

  Map<String, dynamic> toJson() => {'name': name, ...toIce()};

  factory ServerTurn.fromJson(Map<String, dynamic> m) => ServerTurn(
        name: m['name'] as String? ?? 'TURN',
        urls: [for (final u in (m['urls'] as List? ?? const [])) '$u'],
        username: m['username'] as String? ?? '',
        credential: m['credential'] as String? ?? '',
      );
}

/// TURN-серверы, общие для всех: хранятся в Supabase (миграция ice_servers),
/// приходят после входа и запоминаются на случай, если сервер не ответит.
class ServerIce {
  ServerIce._();

  static const _kCache = 'server_ice_cache';

  static List<ServerTurn> servers = const [];

  /// Для RTCPeerConnection.
  static List<Map<String, dynamic>> get iceServers => [for (final s in servers) s.toIce()];

  static Future<void> loadCached() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCache);
      if (raw == null) return;
      servers = [for (final m in jsonDecode(raw) as List) ServerTurn.fromJson(Map<String, dynamic>.from(m as Map))];
    } catch (e) {
      debugPrint('ice cache failed: $e');
    }
  }

  /// Забирает список с сервера. Ошибки не страшны: останется сохранённый.
  static Future<void> refresh(SupabaseClient db) async {
    if (db.auth.currentUser == null) return;
    try {
      final raw = await db.rpc('get_ice_servers').timeout(const Duration(seconds: 6));
      servers = [for (final m in raw as List) ServerTurn.fromJson(Map<String, dynamic>.from(m as Map))];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCache, jsonEncode([for (final s in servers) s.toJson()]));
    } on PostgrestException catch (e) {
      // PGRST202: миграция ice_servers ещё не выполнена — TURN только из настроек.
      if (e.code != 'PGRST202') debugPrint('get_ice_servers failed: ${e.message}');
    } catch (e) {
      debugPrint('get_ice_servers failed: $e');
    }
  }
}
