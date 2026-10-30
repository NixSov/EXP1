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

  static bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  /// Найденное при последней проверке обновление (для баннера на главной).
  static final available = ValueNotifier<AppUpdate?>(null);

  static String get _proxy {
    // Посредник, который сейчас отвечает быстрее всех.
    final url = AppState.instance.supabaseReady ? '${AppState.instance.route.proxyUrl ?? ''}' : '';
    return url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  }

  /// Сначала напрямую, при ошибке — через посредника.
  static Future<T> _either<T>(Future<T> Function(String base) direct, Future<T> Function(String base) proxied) async {
    try {
      return await direct('https://api.github.com/repos/$repo');
    } catch (e) {
      if (_proxy.isEmpty) rethrow;
      debugPrint('github direct failed, via proxy: $e');
      return proxied('$_proxy/gh');
    }
  }

  /// Ищет выпуск новее этой сборки. null — обновлений нет.
  static Future<AppUpdate?> check() async {
    if (!supported) return null;
    final fileName = await _fileName();
    Future<List<dynamic>> load(String url) async {
      final response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw HttpException('GitHub ответил ${response.statusCode}');
      }
      return jsonDecode(response.body) as List<dynamic>;
    }

    final releases = await _either(
      (base) => load('$base/releases?per_page=20'),
      (base) => load('$base/releases'),
    );
    AppUpdate? best;
    for (final r in releases.cast<Map<String, dynamic>>()) {
      final tag = r['tag_name'] as String? ?? '';
      if (!tag.startsWith(_tagPrefix) || r['draft'] == true || r['prerelease'] == true) continue;
      final build = int.tryParse(tag.substring(_tagPrefix.length)) ?? 0;
      if (build <= currentBuild || (best != null && build <= best.build)) continue;
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
  static Future<File> download(AppUpdate update, void Function(double) onProgress) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${update.fileName}');
    final path = 'releases/download/${update.tag}/${update.fileName}';
    try {
      await _downloadTo('https://github.com/$repo/$path', file, update.size, onProgress);
    } catch (e) {
      if (_proxy.isEmpty) rethrow;
      debugPrint('github download failed, via proxy: $e');
      onProgress(0);
      await _downloadTo('$_proxy/gh/download/${update.tag}/${update.fileName}', file, update.size, onProgress);
    }
    return file;
  }

  static Future<void> _downloadTo(String url, File file, int size, void Function(double) onProgress) async {
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw HttpException('Сервер ответил ${response.statusCode}');
      final total = response.contentLength ?? size;
      final sink = file.openWrite();
      var received = 0;
      try {
        // Если загрузка встала на 30 секунд — считаем, что связь пропала.
        await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress(received / total);
        }
      } finally {
        await sink.close();
      }
      if (size > 0 && received != size) {
        throw HttpException('Файл скачался не полностью ($received из $size байт)');
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
      await Process.start(
        file.path,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    }
  }
}
