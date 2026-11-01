import 'dart:async';

import 'package:http/http.dart' as http;

/// В браузере соединениями управляет сам браузер.
http.Client newHttpClient() => http.Client();

/// Время ответа в мс или null, если не ответил за 5 секунд.
Future<int?> measureUrl(Uri url) async {
  final sw = Stopwatch()..start();
  try {
    final response = await http.get(url).timeout(const Duration(seconds: 5));
    return response.statusCode < 500 ? sw.elapsedMilliseconds : null;
  } catch (_) {
    return null;
  }
}

/// Ошибка соединения (а не ответ сервера с ошибкой).
bool isConnectionError(Object e) => e is TimeoutException || e is http.ClientException;
