@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shronshiki/services/server_route.dart';

// Живая проверка посредника на Apps Script (запуск вручную: --tags live --run-skipped).
// Прямой путь и «Vercel» — чёрные дыры, Deno приостановлен, Apps Script — эмулятор
// с настоящим proxy/apps_script_proxy.gs (адрес в GAS_URL).
void main() {
  test('вход и запросы к базе через Apps Script', () async {
    final hole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    hole.listen((_) {});
    SharedPreferences.setMockInitialValues({});
    final supabase = 'https://127.0.0.1:${hole.port}';
    final route = await ServerRoute.create(
      supabaseUrl: supabase,
      proxyUrl: 'https://127.0.0.1:${hole.port}/api,'
          'https://shronshiki-proxy.nixsov.deno.net,'
          '${const String.fromEnvironment('GAS_URL')}',
    );
    final client = route.createClient();
    const key = String.fromEnvironment('KEY');
    final sw = Stopwatch()..start();
    final login = await client.post(
      Uri.parse('$supabase/auth/v1/token?grant_type=password'),
      headers: {'apikey': key, 'content-type': 'application/json'},
      body: jsonEncode({'email': 'test-bot-web@example.com', 'password': 'test-bot-web-123'}),
    );
    // ignore: avoid_print
    print('вход: ${login.statusCode} за ${sw.elapsedMilliseconds} мс, ${route.description}');
    expect(login.statusCode, 200);
    final token = (jsonDecode(login.body) as Map)['access_token'] as String;
    sw.reset();
    final ice = await client.post(
      Uri.parse('$supabase/rest/v1/rpc/get_ice_servers'),
      headers: {'apikey': key, 'authorization': 'Bearer $token', 'content-type': 'application/json'},
      body: '{}',
    );
    // ignore: avoid_print
    print('TURN с сервера: ${ice.statusCode} за ${sw.elapsedMilliseconds} мс ${ice.body.substring(0, 30)}…');
    expect(ice.statusCode, 200);
    final rooms = await client.get(
      Uri.parse('$supabase/rest/v1/rooms?select=code,name&code=eq.APZB4G'),
      headers: {'apikey': key, 'authorization': 'Bearer $token'},
    );
    // ignore: avoid_print
    print('комнаты с фильтром: ${rooms.statusCode} ${rooms.body}');
    expect(rooms.body, contains('APZB4G'));
    client.close();
    await hole.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
