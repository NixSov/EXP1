import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/chats.dart';
import '../widgets/chat_bubble.dart';
import 'errors.dart';

/// Постоянный чат по ключу. Новые сообщения забираются опросом раз в 3 секунды,
/// пока экран открыт и приложение на виду; старые — при прокрутке вверх.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat});

  final PersistentChat chat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  static const _pollEvery = Duration(seconds: 3);

  final _repo = ChatsRepository(AppState.instance.db);
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final List<PersistentMessage> _messages = [];
  Timer? _timer;
  bool _loading = true;
  bool _polling = false;
  bool _sending = false;
  bool _loadingOlder = false;
  bool _noOlder = false;
  String? _error;

  String? get _me => AppState.instance.db.auth.currentUser?.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    unawaited(_poll());
    _timer = Timer.periodic(_pollEvery, (_) => unawaited(_poll()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // В фоне не опрашиваем: это тратит лимит посредника.
    if (state == AppLifecycleState.resumed) {
      _timer ??= Timer.periodic(_pollEvery, (_) => unawaited(_poll()));
      unawaited(_poll());
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final after = _messages.isEmpty ? 0 : _messages.last.id;
      final fresh = await _repo.messages(widget.chat.id, after: after);
      if (!mounted) return;
      setState(() {
        _messages.addAll(fresh.where((m) => m.id > after));
        _loading = false;
        _error = null;
        // При открытии пришли последние 100 — если меньше, старых нет.
        if (after == 0 && fresh.length < 100) _noOlder = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      _polling = false;
    }
  }

  void _onScroll() {
    // Список перевёрнут: «верх» переписки — это конец прокрутки.
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300) unawaited(_loadOlder());
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || _noOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    try {
      final older = await _repo.messages(widget.chat.id, before: _messages.first.id);
      if (!mounted) return;
      setState(() {
        _messages.insertAll(0, older);
        if (older.length < 50) _noOlder = true;
      });
    } catch (_) {
      // Не загрузилось — попробуем при следующей прокрутке.
    } finally {
      _loadingOlder = false;
    }
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _repo.send(widget.chat.id, body);
      _text.clear();
      await _poll();
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
      }
    } catch (e) {
      if (mounted) showError(context, 'Не отправилось: ${describeError(e)}');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _copyInvite() {
    Clipboard.setData(ClipboardData(text: widget.chat.inviteText));
    showError(context, 'Ключ чата скопирован');
  }

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из чата?'),
        content: const Text('Переписка останется у остальных. Вернуться можно по ключу.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repo.leave(widget.chat.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final me = _me;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.chat.name, overflow: TextOverflow.ellipsis),
            Text('Ключ: ${widget.chat.code}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Пригласить (скопировать ключ)',
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: _copyInvite,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'leave') unawaited(_leave());
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'leave', child: Text('Выйти из чата')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null && _messages.isNotEmpty)
              Container(
                width: double.infinity,
                color: scheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Text('Нет связи с сервером', style: TextStyle(color: scheme.onErrorContainer)),
              ),
            Expanded(
              child: _loading
                  ? Center(
                      child: _error != null
                          ? Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))
                          : const CircularProgressIndicator(),
                    )
                  : _messages.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('Сообщений пока нет. Напишите первым!\n'
                                'Позовите друзей: значок вверху копирует ключ чата.',
                                textAlign: TextAlign.center),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            final index = _messages.length - 1 - i;
                            final m = _messages[index];
                            final previous = index > 0 ? _messages[index - 1] : null;
                            return ChatBubble(
                              name: m.name,
                              body: m.body,
                              at: m.at,
                              mine: m.userId != null && m.userId == me,
                              showName: previous == null ||
                                  previous.userId != m.userId ||
                                  m.at.difference(previous.at).inMinutes > 30,
                            );
                          },
                        ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 2000,
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
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
