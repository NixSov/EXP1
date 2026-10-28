import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// HTTP-клиент с коротким таймаутом соединения.
http.Client newHttpClient() => IOClient(HttpClient()..connectionTimeout = const Duration(seconds: 6));

/// Время ответа в мс или null, если не ответил за 5 секунд.
Future<int?> measureUrl(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final sw = Stopwatch()..start();
  try {
    final request = await client.getUrl(url).timeout(const Duration(seconds: 5));
    request.persistentConnection = false;
    final response = await request.close().timeout(const Duration(seconds: 5));
    await response.drain<void>().timeout(const Duration(seconds: 5));
    // 401 на /auth/v1/health без ключа — тоже ответ: сервер доступен.
    return response.statusCode < 500 ? sw.elapsedMilliseconds : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Ошибка соединения (а не ответ сервера с ошибкой).
bool isConnectionError(Object e) =>
    e is SocketException || e is TimeoutException || e is HandshakeException || e is http.ClientException;
