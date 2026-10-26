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
  });

  final String supabaseUrl;
  final String supabaseAnonKey;
  final List<String> turnUrls;
  final String turnUsername;
  final String turnCredential;

  static const _stunUrls = [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
  ];

  bool get isConfigured =>
      supabaseUrl.startsWith('http') && supabaseAnonKey.isNotEmpty;

  /// Список ICE-серверов для RTCPeerConnection.
  List<Map<String, dynamic>> get iceServers => [
        {'urls': _stunUrls},
        if (turnUrls.isNotEmpty && turnUsername.isNotEmpty)
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

  static Future<AppConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    String pick(String key, String fallback) {
      final stored = prefs.getString(key);
      return (stored != null && stored.trim().isNotEmpty) ? stored.trim() : fallback;
    }

    return AppConfig(
      supabaseUrl: pick(_kUrl, const String.fromEnvironment('SUPABASE_URL')),
      supabaseAnonKey: pick(_kKey, const String.fromEnvironment('SUPABASE_ANON_KEY')),
      turnUrls: splitUrls(pick(_kTurnUrls, const String.fromEnvironment('TURN_URLS'))),
      turnUsername: pick(_kTurnUser, const String.fromEnvironment('TURN_USERNAME')),
      turnCredential: pick(_kTurnPass, const String.fromEnvironment('TURN_CREDENTIAL')),
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
  }
}
