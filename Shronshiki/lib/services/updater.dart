import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';

/// Новая версия из выпусков (Releases) на GitHub.
class AppUpdate {
  AppUpdate({
    required this.build,
    required this.tag,
    required this.notes,
    required this.fileName,
    required this.size,
  });

  final int build;
  final String tag;
  final String notes;

  /// Файл для этой платформы: APK для Android, установщик для Windows.
  final String fileName;
  final int size;
}

/// Обновление приложения с GitHub одной кнопкой.
///
/// CI выкладывает каждую сборку как выпуск `shronshiki-b<номер>` с APK и
/// установщиком. Если GitHub без VPN не открывается, запросы идут через
/// посредника на Deno (`/gh/…`).
class Updater {
  Updater._();

  static const repo = 'NixSov/EXP1';
  static const _tagPrefix = 'shronshiki-b';
  static const _channel = MethodChannel('shronshiki/call');

  /// Номер этой сборки (задаёт CI). 0 — собрано вручную.
  static const currentBuild = int.fromEnvironment('APP_BUILD');

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  /// Найденное при последней проверке обновление (для баннера на главной).
  static final available = ValueNotifier<AppUpdate?>(null);

  static List<String> get _proxies {
    try {
      final state = AppState.instance;
      if (!state.supabaseReady) return const [];
      return {
            if (state.route.proxyUrl != null) state.route.proxyUrl!,
            ...state.route.proxies,
          }
          .where((url) => !url.path.contains('/macros/s/'))
          .map((url) => url.toString().replaceAll(RegExp(r'/+$'), ''))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Static feeds avoid GitHub's shared-IP API quota. All routes are read-only.
  @visibleForTesting
  static Future<List<dynamic>> loadReleases({
    Iterable<String> proxies = const [],
    http.Client? client,
  }) async {
    final transport = client ?? http.Client();
    try {
      for (final url in {
        'https://raw.githubusercontent.com/$repo/gh-pages/updates.json',
        'https://nixsov.github.io/EXP1/updates.json',
        'https://api.github.com/repos/$repo/releases?per_page=20',
        for (final proxy in proxies) '$proxy/gh/releases',
      }) {
        try {
          final response = await transport
              .get(
                Uri.parse(url),
                headers: {
                  'Accept': 'application/json',
                  'User-Agent': 'Shronshiki-Updater',
                },
              )
              .timeout(const Duration(seconds: 8));
          if (response.statusCode != 200) continue;
          final data = jsonDecode(response.body);
          if (data is List &&
              data.every(
                (item) =>
                    item is Map<String, dynamic> && item['tag_name'] is String,
              )) {
            return data;
          }
        } catch (e) {
          debugPrint('update source failed: $url: $e');
        }
      }
      throw const HttpException(
        'Серверы обновлений временно недоступны. Повторите проверку позже.',
      );
    } finally {
      if (client == null) transport.close();
    }
  }

  /// Ищет выпуск новее этой сборки. null — обновлений нет.
  static Future<AppUpdate?> check() async {
    if (!supported) return null;
    final fileName = await _fileName();
    final releases = await loadReleases(proxies: _proxies);
    AppUpdate? best;
    for (final r in releases.cast<Map<String, dynamic>>()) {
      final tag = r['tag_name'] as String? ?? '';
      if (!tag.startsWith(_tagPrefix) ||
          r['draft'] == true ||
          r['prerelease'] == true) {
        continue;
      }
      final build = int.tryParse(tag.substring(_tagPrefix.length)) ?? 0;
      if (build <= currentBuild || (best != null && build <= best.build)) {
        continue;
      }
      final asset = (r['assets'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .where((a) => a['name'] == fileName)
          .firstOrNull;
      if (asset == null) continue;
      best = AppUpdate(
        build: build,
        tag: tag,
        notes: (r['body'] as String? ?? '').trim(),
        fileName: fileName,
        size: (asset['size'] as num?)?.toInt() ?? 0,
      );
    }
    available.value = best;
    return best;
  }

  static Future<String> _fileName() async {
    if (Platform.isWindows) return 'Shronshiki-Setup.exe';
    String abi = '';
    try {
      abi = await _channel.invokeMethod<String>('abi') ?? '';
    } catch (_) {}
    return abi.contains('arm64') || abi.contains('x86_64') || abi.isEmpty
        ? 'Shronshiki.apk'
        : 'Shronshiki-armv7.apk';
  }

  /// Скачивает файл обновления. [onProgress] — доля от 0 до 1.
  static Future<File> download(
    AppUpdate update,
    void Function(double) onProgress,
  ) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${update.fileName}');
    final path = 'releases/download/${update.tag}/${update.fileName}';
    Object? lastError;
    for (final url in [
      'https://github.com/$repo/$path',
      for (final proxy in _proxies)
        '$proxy/gh/download/${update.tag}/${update.fileName}',
    ]) {
      try {
        onProgress(0);
        await _downloadTo(url, file, update.size, onProgress);
        return file;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const HttpException('Не удалось скачать обновление');
  }

  static Future<void> _downloadTo(
    String url,
    File file,
    int size,
    void Function(double) onProgress,
  ) async {
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw HttpException('Сервер ответил ${response.statusCode}');
      }
      final total = response.contentLength ?? size;
      final sink = file.openWrite();
      var received = 0;
      try {
        // Если загрузка встала на 30 секунд — считаем, что связь пропала.
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress(received / total);
        }
      } finally {
        await sink.close();
      }
      if (size > 0 && received != size) {
        throw HttpException(
          'Файл скачался не полностью ($received из $size байт)',
        );
      }
    } finally {
      client.close();
    }
  }

  /// Ставит скачанное обновление. На Windows программа закроется, установщик
  /// поставит новую версию и сам запустит её.
  static Future<void> install(File file) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('installApk', {'path': file.path});
      return;
    }
    if (Platform.isWindows) {
      await Process.start(file.path, [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
      ], mode: ProcessStartMode.detached);
      exit(0);
    }
  }
}
