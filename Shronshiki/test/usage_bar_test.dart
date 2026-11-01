import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/widgets/usage_bar.dart';

void main() {
  testWidgets('линия показывает остаток по самому тесному лимиту', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: UsageBar(
            load: () async => {
              'resets': '2026-11-01',
              'limits': [
                {'key': 'proxy_requests', 'title': 'Посредник (Vercel)', 'used': 250000, 'limit': 1000000, 'hours_left': 1041.6},
                {'key': 'turn_bytes', 'title': 'TURN (ExpressTURN)', 'used': 600e9, 'limit': 1000e9, 'hours_left': 13333.3},
              ],
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Осталось ≈ 521 ч разговора'), findsOneWidget);
    expect(find.text('до 1 ноября'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.75, 0.001));
    expect(find.textContaining('250 тыс. из 1 млн запросов'), findsOneWidget);
    expect(find.textContaining('600 из 1000 ГБ'), findsOneWidget);
  });
}
