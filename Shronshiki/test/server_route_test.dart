import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/services/server_route.dart';

void main() {
  test('несколько посредников через запятую, без хвостовых слэшей', () {
    final list = ServerRoute.parseProxies(
      ' https://a.vercel.app/api/, https://b.deno.net \n',
    );
    expect(list.map((u) => u.toString()), ['https://a.vercel.app/api', 'https://b.deno.net']);
    expect(ServerRoute.parseProxies('  '), isEmpty);
  });
}
