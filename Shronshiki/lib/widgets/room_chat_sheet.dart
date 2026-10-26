import 'package:flutter/material.dart';

import '../services/call_controller.dart';
import '../services/signaling.dart';

/// Открывает мини-чат комнаты снизу экрана.
Future<void> showRoomChat(BuildContext context, CallController call) async {
  call.chatOpen = true;
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: 0.8,
        child: _RoomChat(call: call),
      ),
    );
  } finally {
    call.chatOpen = false;
  }
}

class _RoomChat extends StatefulWidget {
  const _RoomChat({required this.call});

  final CallController call;

  @override
  State<_RoomChat> createState() => _RoomChatState();
}

class _RoomChatState extends State<_RoomChat> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  String? _error;
  int _shown = 0;

  CallController get _call => widget.call;

  @override
  void initState() {
    super.initState();
    _call.addListener(_onCall);
    _shown = _call.chat.length;
  }

  @override
  void dispose() {
    _call.removeListener(_onCall);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onCall() {
    if (!mounted) return;
    if (!_call.isActive) {
      Navigator.of(context).maybePop();
      return;
    }
    final grew = _call.chat.length != _shown;
    _shown = _call.chat.length;
    setState(() {});
    // Новое сообщение — прокручиваем к нему (список перевёрнут, низ — это 0).
    if (grew && _scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _call.sendChat(text);
      _text.clear();
    } catch (e) {
      setState(() => _error = 'Не отправилось. Проверьте связь и попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final messages = _call.chat;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Text('Чат комнаты', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('очистится, когда все выйдут',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: !_call.chatSupported
                ? const _Hint('Чат пока недоступен: выполните в Supabase SQL-миграцию '
                    '20261026190000_room_chat.sql')
                : messages.isEmpty
                    ? const _Hint('Сообщений пока нет. Напишите первым!')
                    : ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.all(12),
                        itemCount: messages.length,
                        itemBuilder: (context, i) {
                          final index = messages.length - 1 - i;
                          final m = messages[index];
                          final previous = index > 0 ? messages[index - 1] : null;
                          return _Bubble(
                            message: m,
                            mine: m.peerId == _call.peerId,
                            showName: previous == null || previous.peerId != m.peerId,
                          );
                        },
                      ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      enabled: _call.chatSupported,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 1000,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Сообщение',
                        counterText: '',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Отправить',
                    onPressed: _sending || !_call.chatSupported ? null : _send,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.showName});

  final ChatMessage message;
  final bool mine;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(message.at).format(context);
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
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showName && !mine)
                    Text(message.name,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w600,
                            )),
                  SelectableText(
                    message.body,
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

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );
}
