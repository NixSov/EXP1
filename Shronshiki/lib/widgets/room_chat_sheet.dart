import 'package:flutter/material.dart';

import '../services/call_controller.dart';
import '../services/signaling.dart';
import 'chat_bubble.dart';

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

  /// Подсказка упоминаний: кого можно упомянуть и что набрано после «@».
  List<({String name, bool inRoom})> _candidates = const [];
  String? _mentionQuery;

  CallController get _call => widget.call;

  @override
  void initState() {
    super.initState();
    _call.addListener(_onCall);
    _shown = _call.chat.length;
    _text.addListener(_onText);
    _call.mentionCandidates().then((names) {
      if (mounted) setState(() => _candidates = names);
    });
  }

  /// Текст до курсора заканчивается на «@что-то» — показываем подсказку.
  void _onText() {
    final value = _text.value;
    final cursor = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    final before = value.text.substring(0, cursor.clamp(0, value.text.length));
    final match = RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(before);
    final query = match?.group(1);
    if (query != _mentionQuery) setState(() => _mentionQuery = query);
  }

  List<({String name, bool inRoom})> get _suggestions {
    final query = _mentionQuery?.toLowerCase();
    if (query == null) return const [];
    return [
      (name: 'все', inRoom: false),
      ..._candidates,
    ].where((c) => c.name.toLowerCase().startsWith(query)).take(8).toList();
  }

  void _insertMention(String name) {
    final value = _text.value;
    final cursor = value.selection.isValid ? value.selection.baseOffset : value.text.length;
    final before = value.text.substring(0, cursor);
    final after = value.text.substring(cursor);
    final start = before.lastIndexOf('@');
    if (start < 0) return;
    final inserted = '${before.substring(0, start)}@$name ';
    _text.value = TextEditingValue(
      text: '$inserted$after',
      selection: TextSelection.collapsed(offset: inserted.length),
    );
  }

  bool _mentionsMe(ChatMessage m) {
    if (m.peerId == _call.peerId) return false;
    final body = m.body.toLowerCase();
    return body.contains('@${_call.displayName.toLowerCase()}') ||
        RegExp(r'(^|[^\p{L}\p{N}_])@(все|all)($|[^\p{L}\p{N}_])', unicode: true).hasMatch(body);
  }

  @override
  void dispose() {
    _call.removeListener(_onCall);
    _text.removeListener(_onText);
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
                          return ChatBubble(
                            name: m.name,
                            body: m.body,
                            at: m.at,
                            mine: m.peerId == _call.peerId,
                            showName: previous == null || previous.peerId != m.peerId,
                            highlight: _mentionsMe(m),
                          );
                        },
                      ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          if (_suggestions.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                children: [
                  for (final c in _suggestions)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        avatar: Icon(
                          c.name == 'все'
                              ? Icons.groups
                              : (c.inRoom ? Icons.graphic_eq : Icons.person_outline),
                          size: 18,
                        ),
                        label: Text('@${c.name}'),
                        onPressed: () => _insertMention(c.name),
                      ),
                    ),
                ],
              ),
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
                        hintText: 'Сообщение (@имя — упомянуть)',
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
