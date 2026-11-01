import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Кусок текста: обычный или ссылка (с адресом, который открывать).
typedef TextPiece = ({String text, Uri? link});

/// Делит текст на обычные куски и ссылки: http(s)://…, www.… и приглашения
/// shronshiki://… . Знаки препинания в конце к ссылке не относятся.
List<TextPiece> splitLinks(String text) {
  final pieces = <TextPiece>[];
  var last = 0;
  for (final m in _linkPattern.allMatches(text)) {
    var raw = m.group(0)!;
    // «Смотри https://example.com/page.» — точка, запятая, скобка в конце не часть ссылки.
    final trailing = RegExp(r'[.,!?:;)\]»"]+$').firstMatch(raw);
    if (trailing != null) raw = raw.substring(0, trailing.start);
    if (raw.isEmpty) continue;
    final uri = Uri.tryParse(raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw);
    if (uri == null || uri.host.isEmpty && uri.scheme != 'shronshiki') continue;
    if (m.start > last) pieces.add((text: text.substring(last, m.start), link: null));
    pieces.add((text: raw, link: uri));
    last = m.start + raw.length;
  }
  if (last < text.length) pieces.add((text: text.substring(last), link: null));
  return pieces;
}

final _linkPattern = RegExp(r'(?:https?://|shronshiki://|www\.)[^\s<>"]+', caseSensitive: false);

/// Текст сообщения, в котором ссылки подчёркнуты и открываются нажатием
/// (в браузере или, для приглашений shronshiki://, в самом приложении).
class LinkedText extends StatefulWidget {
  const LinkedText(this.text, {super.key, this.style, this.linkColor});

  final String text;
  final TextStyle? style;
  final Color? linkColor;

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  Future<void> _open(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Не удалось открыть $uri')));
    }
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final pieces = splitLinks(widget.text);
    if (pieces.every((p) => p.link == null)) return SelectableText(widget.text, style: widget.style);
    final linkStyle = TextStyle(
      color: widget.linkColor,
      decoration: TextDecoration.underline,
      decorationColor: widget.linkColor ?? widget.style?.color,
    );
    return SelectableText.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final p in pieces)
            if (p.link == null)
              TextSpan(text: p.text)
            else
              TextSpan(
                text: p.text,
                style: linkStyle,
                recognizer: (TapGestureRecognizer()..onTap = () => _open(p.link!)).also(_recognizers.add),
              ),
        ],
      ),
    );
  }
}

extension<T> on T {
  T also(void Function(T) action) {
    action(this);
    return this;
  }
}
