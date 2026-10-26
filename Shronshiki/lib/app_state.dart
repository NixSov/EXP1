import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'services/rooms.dart';
import 'services/server_route.dart';
import 'services/settings.dart';
import 'services/theme_settings.dart';

/// Общие объекты приложения.
class AppState {
  AppState._(this.config, this.settings, this.theme);

  static late AppState instance;

  AppConfig config;
  final AudioSettings settings;
  final ThemeSettings theme;

  /// Код комнаты из ссылки shronshiki://join/КОД, ожидающий входа.
  final ValueNotifier<String?> pendingJoinCode = ValueNotifier(null);

  bool supabaseReady = false;

  /// Путь к Supabase: напрямую или через посредника. Создаётся вместе с Supabase.
  late ServerRoute route;

  SupabaseClient get db => Supabase.instance.client;
  RoomsRepository get rooms => RoomsRepository(db);

  static Future<AppState> init() async {
    final state = AppState._(
      await AppConfig.load(),
      await AudioSettings.load(),
      await ThemeSettings.load(),
    );
    instance = state;
    if (state.config.isConfigured) await state.initSupabase();
    state._listenLinks();
    return state;
  }

  Future<void> initSupabase() async {
    if (supabaseReady) return;
    route = await ServerRoute.create(supabaseUrl: config.supabaseUrl, proxyUrl: config.proxyUrl);
    // Меряем оба пути в фоне; первые запросы при необходимости сами уйдут через посредника.
    unawaited(route.probe(force: true));
    await Supabase.initialize(
      url: config.supabaseUrl,
      // Подходит и старый anon key (eyJ...), и новый publishable key (sb_publishable_...).
      publishableKey: config.supabaseAnonKey,
      // По умолчанию Realtime отключается при сворачивании приложения — это оборвало бы
      // звонок в фоне. Сокет живёт, пока работает foreground service.
      realtimeLifecycleOptions: const RealtimeLifecycleOptions.manual(),
      httpClient: route.createClient(),
    );
    supabaseReady = true;
  }

  void _listenLinks() {
    if (kIsWeb) return;
    try {
      AppLinks().uriLinkStream.listen((uri) {
        final code = RoomsRepository.normalizeCode(uri.toString());
        if (code != null) pendingJoinCode.value = code;
      }, onError: (_) {});
    } catch (_) {
      // Платформа без поддержки ссылок — вход только по коду.
    }
  }
}

extension UserDisplayName on User {
  String get displayName {
    final name = (userMetadata?['display_name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final mail = email;
    if (mail != null && mail.contains('@')) return mail.split('@').first;
    return 'Гость';
  }
}
