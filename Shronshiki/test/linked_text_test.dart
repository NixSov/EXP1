import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/widgets/linked_text.dart';

void main() {
  List<String?> links(String text) => [for (final p in splitLinks(text)) p.link?.toString()];

  test('ссылки находятся, знаки препинания в конце не попадают в ссылку', () {
    final pieces = splitLinks('Смотри https://example.com/a?b=1, и www.ya.ru.');
    expect(pieces.map((p) => p.text).toList(), ['Смотри ', 'https://example.com/a?b=1', ', и ', 'www.ya.ru', '.']);
    expect(links('Смотри https://example.com/a?b=1, и www.ya.ru.'),
        [null, 'https://example.com/a?b=1', null, 'https://www.ya.ru', null]);
  });

  test('приглашения и текст без ссылок', () {
    expect(links('заходи shronshiki://join/ABC234'), [null, 'shronshiki://join/ABC234']);
    expect(links('сайт https://nixsov.github.io/EXP1/#/join/ABC234'),
        [null, 'https://nixsov.github.io/EXP1/#/join/ABC234']);
    expect(splitLinks('просто текст').single.link, isNull);
    expect(splitLinks('(https://a.ru)').map((p) => p.text).toList(), ['(', 'https://a.ru', ')']);
  });
}
