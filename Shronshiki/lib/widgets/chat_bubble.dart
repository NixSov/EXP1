import 'package:flutter/material.dart';

/// Сообщение в чате: своё — справа цветом темы, чужое — слева с именем.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.name,
    required this.body,
    required this.at,
    required this.mine,
    required this.showName,
    this.highlight = false,
  });

  final String name;
  final String body;
  final DateTime at;
  final bool mine;
  final bool showName;

  /// Например, в сообщении упомянули меня — подсвечиваем рамкой.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clock = TimeOfDay.fromDateTime(at).format(context);
    // В постоянном чате сообщения бывают за разные дни — тогда с датой.
    final now = DateTime.now();
    final today = at.year == now.year && at.month == now.month && at.day == now.day;
    String two(int n) => n.toString().padLeft(2, '0');
    final time = today ? clock : '${two(at.day)}.${two(at.month)} $clock';
    return Padding(
      padding: EdgeInsets.only(top: showName ? 10 : 3),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? scheme.primary : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
              border: highlight ? Border.all(color: scheme.primary, width: 2) : null,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showName && !mine)
                    Text(name,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            )),
                  SelectableText(
                    body,
                    style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    time,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: (mine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: 0.7),
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
