@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shronshiki/services/server_route.dart';

// Живая проверка переключения путей (запускается вручную: --tags live).
// Прямой путь — «чёрная дыра» (соединение принимается, ответа нет), первый
// посредник — приостановленный Deno (503), второй — Vercel.
void main() {
  test('запрос уходит через живого посредника', () async {
    final hole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    hole.listen((_) {});
    SharedPreferences.setMockInitialValues({'route_mode': 'proxy'});
    final route = await ServerRoute.create(
      supabaseUrl: 'https://127.0.0.1:${hole.port}',
      proxyUrl: const String.fromEnvironment('PROXIES'),
    );
    final client = route.createClient();
    final key = const String.fromEnvironment('KEY');
    for (final mode in [RouteMode.proxy, RouteMode.auto]) {
      route.mode = mode;
      final sw = Stopwatch()..start();
      final r = await client.get(Uri.parse('https://127.0.0.1:${hole.port}/auth/v1/health'), headers: {'apikey': key});
      // ignore: avoid_print
      print('$mode: ${r.statusCode} за ${sw.elapsedMilliseconds} мс, ${route.description}');
      expect(r.statusCode, 200);
    }
    // Запрос к базе со строкой параметров: фильтр должен дойти до Supabase как есть.
    final rows = await client.get(
      Uri.parse('https://127.0.0.1:${hole.port}/rest/v1/rooms?select=code&code=eq.ZZZZZZ'),
      headers: {'apikey': key},
    );
    // ignore: avoid_print
    print('rooms: ${rows.statusCode} ${rows.body}');
    expect(rows.statusCode, anyOf(200, 401));
    expect(rows.body, isNot(contains('PGRST100')));
    client.close();
    await hole.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
