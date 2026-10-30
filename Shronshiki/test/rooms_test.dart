import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/config.dart';
import 'package:shronshiki/services/rooms.dart';

void main() {
  group('RoomsRepository.normalizeCode', () {
    test('принимает код в любом регистре и с пробелами', () {
      expect(RoomsRepository.normalizeCode(' abc234 '), 'ABC234');
      expect(RoomsRepository.normalizeCode('ABC-234'), 'ABC234');
    });

    test('достаёт код из ссылки-приглашения', () {
      expect(RoomsRepository.normalizeCode('shronshiki://join/XYZ789'), 'XYZ789');
      expect(
        RoomsRepository.normalizeCode('Заходи!\nКод: XYZ789\nshronshiki://join/XYZ789'),
        'XYZ789',
      );
    });

    test('отклоняет код неверной длины', () {
      expect(RoomsRepository.normalizeCode('ABC23'), isNull);
      expect(RoomsRepository.normalizeCode('ABC2345'), isNull);
      expect(RoomsRepository.normalizeCode(''), isNull);
    });
  });

  group('AppConfig', () {
    AppConfig make({List<String> turn = const [], String user = ''}) => AppConfig(
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
      expect(AppConfig.splitUrls('turn:a:80, turn:b:443\nturns:c:443'), hasLength(3));
    });
  });
}
