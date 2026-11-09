import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shronshiki/services/updater.dart';

void main() {
  final feed = jsonEncode([
    {
      'tag_name': 'shronshiki-b124',
      'draft': false,
      'prerelease': false,
      'body': 'update',
      'assets': [
        {'name': 'Shronshiki-Setup.exe', 'size': 1234567},
      ],
    },
  ]);
  test('static feed works without spending GitHub API quota', () async {
    final calls = <String>[];
    final client = MockClient((request) async {
      calls.add(request.url.host);
      return http.Response(feed, 200);
    });
    final releases = await Updater.loadReleases(client: client);
    expect(releases.single['tag_name'], 'shronshiki-b124');
    expect(calls, ['raw.githubusercontent.com']);
    client.close();
  });
  test('403 and a failed proxy fall through to another proxy', () async {
    final calls = <String>[];
    final client = MockClient((request) async {
      final host = request.url.host;
      calls.add(host);
      return http.Response(
        host == 'second.test' ? feed : '{}',
        host == 'second.test'
            ? 200
            : host == 'api.github.com'
            ? 403
            : 503,
      );
    });
    expect(
      await Updater.loadReleases(
        client: client,
        proxies: ['https://first.test', 'https://second.test'],
      ),
      isNotEmpty,
    );
    expect(calls, [
      'raw.githubusercontent.com',
      'nixsov.github.io',
      'api.github.com',
      'first.test',
      'second.test',
    ]);
    client.close();
  });
  test(
    'malformed successful response is not treated as an empty update list',
    () async {
      final client = MockClient(
        (request) async => http.Response(
          request.url.host == 'api.github.com' ? feed : '<html>gateway</html>',
          200,
        ),
      );
      expect(await Updater.loadReleases(client: client), isNotEmpty);
      client.close();
    },
  );
  test('all sources failing gives a recoverable error', () async {
    final client = MockClient((_) async => http.Response('{}', 403));
    await expectLater(
      Updater.loadReleases(client: client),
      throwsA(isA<HttpException>()),
    );
    client.close();
  });
  test('Windows update check accepts the static release metadata', () async {
    final update = await http.runWithClient(
      Updater.check,
      () => MockClient((_) async => http.Response(feed, 200)),
    );
    expect(update?.build, 124);
    expect(update?.fileName, 'Shronshiki-Setup.exe');
  }, skip: !Platform.isWindows);
}
