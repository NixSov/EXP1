import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/services/ice_servers.dart';

void main() {
  test('TURN с сервера превращается в iceServer для WebRTC', () {
    final s = ServerTurn.fromJson({
      'name': 'ExpressTURN',
      'urls': ['turn:a:3478?transport=udp', 'turn:a:3478?transport=tcp'],
      'username': 'u',
      'credential': 'p',
    });
    expect(s.toIce(), {
      'urls': ['turn:a:3478?transport=udp', 'turn:a:3478?transport=tcp'],
      'username': 'u',
      'credential': 'p',
    });
    expect(ServerTurn.fromJson(s.toJson()).name, 'ExpressTURN');
  });
}
