import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/config.dart';
import 'package:shronshiki/services/rooms.dart';

void main() {
  test('recent rooms GET sends an empty parameter map to the SDK', () async {
    var requests = 0;
    final db = SupabaseClient(
      'https://example.supabase.co',
      'key',
      httpClient: MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.url.path, '/rest/v1/rpc/recent_rooms');
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    expect(await RoomsRepository(db).recentRooms(), isEmpty);
    expect(requests, 1);
    await db.dispose();
  });
  group('RoomsRepository.normalizeCode', () {
    test('принимает код в любом регистре и с пробелами', () {
      expect(RoomsRepository.normalizeCode(' abc234 '), 'abc234');
      expect(RoomsRepository.normalizeCode('ABC-234'), 'ABC-234');
    });

    test('достаёт код из ссылки-приглашения', () {
      expect(
        RoomsRepository.normalizeCode('shronshiki://join/XYZ789'),
        'XYZ789',
      );
      expect(
        RoomsRepository.normalizeCode(
          'Заходи!\nКод: XYZ789\nshronshiki://join/XYZ789',
        ),
        'XYZ789',
      );
    });

    test('произвольные символы сохраняются в обеих ссылках', () {
      final room = Room(
        id: 'r',
        name: 'Room',
        code: 'Кот /#?% +猫🔒',
        maxParticipants: 4,
      );
      expect(RoomsRepository.normalizeCode(room.inviteLink), room.code);
      expect(RoomsRepository.normalizeCode(room.webLink), room.code);
    });

    test('обычная страница сайта не считается приглашением', () {
      expect(RoomsRepository.normalizeCode(webAppUrl, linkOnly: true), isNull);
    });

    test('отклоняет код неверной длины', () {
      expect(
        RoomsRepository.normalizeCode('Комната №1 / 🔒 #?%'),
        'Комната №1 / 🔒 #?%',
      );
      expect(RoomsRepository.normalizeCode('А' * 65), isNull);
      expect(RoomsRepository.normalizeCode('a\nb'), isNull);
      expect(RoomsRepository.normalizeCode(''), isNull);
    });
  });

  group('AppConfig', () {
    AppConfig make({List<String> turn = const [], String user = ''}) =>
        AppConfig(
          supabaseUrl: 'https://x.supabase.co',
          supabaseAnonKey: 'key',
          turnUrls: turn,
          turnUsername: user,
          turnCredential: 'secret',
        );

    test('без TURN — только STUN', () {
      expect(make().iceServers, hasLength(1));
    });

    test('TURN добавляется, если заданы адрес и логин', () {
      final servers = make(turn: ['turn:a:80'], user: 'u').iceServers;
      expect(servers, hasLength(2));
      expect(servers.last['username'], 'u');
    });

    test('splitUrls понимает запятые и переводы строк', () {
      expect(
        AppConfig.splitUrls('turn:a:80, turn:b:443\nturns:c:443'),
        hasLength(3),
      );
    });
  });
}
