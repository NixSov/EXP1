import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Настройки подключения к серверам.
///
/// Значения по умолчанию берутся из `--dart-define-from-file=config/app_config.json`
/// при сборке. Если приложение собрано без них, адрес Supabase и ключ можно
/// ввести на первом экране — они сохранятся на устройстве.
class AppConfig {
  AppConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    required this.turnUrls,
    required this.turnUsername,
    required this.turnCredential,
    this.proxyUrl = '',
  });

  final String supabaseUrl;
  final String supabaseAnonKey;
  final List<String> turnUrls;
  final String turnUsername;
  final String turnCredential;

  /// Посредник к Supabase на Deno Deploy (https://….deno.dev). Пусто — без посредника.
  final String proxyUrl;

  /// STUN-серверы: через них телефон узнаёт свой внешний адрес. Кроме Google —
  /// российские (Яндекс, Sipnet) на случай, если зарубежные недоступны без VPN.
  static const stunServers = {
    'Google': 'stun:stun.l.google.com:19302',
    'Яндекс': 'stun:stun.rtc.yandex.net:3478',
    'Sipnet': 'stun:stun.sipnet.ru:3478',
    'Cloudflare': 'stun:stun.cloudflare.com:3478',
  };

  bool get hasTurn => turnUrls.isNotEmpty && turnUsername.isNotEmpty;

  bool get isConfigured =>
      supabaseUrl.startsWith('http') && supabaseAnonKey.isNotEmpty;

  /// Список ICE-серверов для RTCPeerConnection.
  List<Map<String, dynamic>> get iceServers => [
        {'urls': stunServers.values.toList()},
        if (hasTurn)
          {
            'urls': turnUrls,
            'username': turnUsername,
            'credential': turnCredential,
          },
      ];

  static const _kUrl = 'cfg_supabase_url';
  static const _kKey = 'cfg_supabase_key';
  static const _kTurnUrls = 'cfg_turn_urls';
  static const _kTurnUser = 'cfg_turn_user';
  static const _kTurnPass = 'cfg_turn_pass';
  static const _kProxy = 'cfg_proxy_url';

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    String pick(String key, String fallback) {
      final stored = prefs.getString(key);
      if (stored != null && stored.trim().isNotEmpty) return stored.trim();
      // Запоминаем вшитое при сборке: обновление с GitHub может прийти без него.
      if (fallback.isNotEmpty) unawaited(prefs.setString(key, fallback));
      return fallback;
    }

    return AppConfig(
      supabaseUrl: pick(_kUrl, const String.fromEnvironment('SUPABASE_URL')),
      supabaseAnonKey: pick(_kKey, const String.fromEnvironment('SUPABASE_ANON_KEY')),
      turnUrls: splitUrls(pick(_kTurnUrls, const String.fromEnvironment('TURN_URLS'))),
      turnUsername: pick(_kTurnUser, const String.fromEnvironment('TURN_USERNAME')),
      turnCredential: pick(_kTurnPass, const String.fromEnvironment('TURN_CREDENTIAL')),
      proxyUrl: pick(_kProxy, const String.fromEnvironment('PROXY_URL')),
    );
  }

  static List<String> splitUrls(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrl, supabaseUrl);
    await prefs.setString(_kKey, supabaseAnonKey);
    await prefs.setString(_kTurnUrls, turnUrls.join(','));
    await prefs.setString(_kTurnUser, turnUsername);
    await prefs.setString(_kTurnPass, turnCredential);
    await prefs.setString(_kProxy, proxyUrl);
  }
}
