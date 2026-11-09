import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shronshiki/services/server_route.dart';

void main() {
  test(
    'GET falls back after gateway failure; POST is never replayed',
    () async {
      final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var writesFirst = 0;
      var writesSecond = 0;
      first.listen((request) async {
        if (request.method == 'POST') writesFirst++;
        await request.drain<void>();
        request.response.statusCode = 502;
        await request.response.close();
      });
      second.listen((request) async {
        if (request.method == 'POST') writesSecond++;
        await request.drain<void>();
        request.response.write('ok');
        await request.response.close();
      });
      final proxies =
          'http://127.0.0.1:${first.port},http://127.0.0.1:${second.port}';
      SharedPreferences.setMockInitialValues({'route_mode': 'proxy'});
      final route = await ServerRoute.create(
        supabaseUrl: 'http://localhost:9',
        proxyUrl: proxies,
      );
      final client = route.createClient();
      addTearDown(() async {
        client.close();
        await first.close(force: true);
        await second.close(force: true);
      });
      // A failed POST must not be sent to the other path, even if the gateway
      // failed after the upstream committed the write.
      final write = await client.post(
        Uri.parse('http://localhost:9/rest/v1/rpc/chat_send'),
        body: '{}',
      );
      expect(write.statusCode, 502);
      expect(writesFirst, 1);
      expect(writesSecond, 0);
      expect(route.proxyUrl!.port, second.port);
      expect(
        (await client.get(Uri.parse('http://localhost:9/rest/v1/rooms'))).body,
        'ok',
      );
    },
  );
}
