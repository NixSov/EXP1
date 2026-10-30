import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../screens/chat_screen.dart';
import '../screens/errors.dart';
import '../services/chats.dart';
import '../services/rooms.dart';

/// Главный экран: кнопка «Вход в чат» и постоянные чаты, в которые я вошёл.
class ChatsSection extends StatefulWidget {
  const ChatsSection({super.key});

  @override
  State<ChatsSection> createState() => ChatsSectionState();
}

class ChatsSectionState extends State<ChatsSection> {
  final _repo = ChatsRepository(AppState.instance.db);
  List<PersistentChat>? _chats;

  /// false — на сервере нет миграции chats.
  bool _supported = true;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  Future<void> reload() async {
    try {
      final chats = await _repo.myChats();
      if (mounted) setState(() => _chats = chats);
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST202' && mounted) setState(() => _supported = false);
    } catch (_) {
      // Нет связи — список покажем при следующем обновлении.
    }
  }

  Future<void> _open(PersistentChat chat) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatScreen(chat: chat)));
    // Вернулись — обновим непрочитанные (или чат исчез, если из него вышли).
    unawaited(reload());
  }

  Future<void> _enter() async {
    final chat = await showDialog<PersistentChat>(
      context: context,
      builder: (_) => _EnterChatDialog(repo: _repo),
    );
    if (chat == null || !mounted) return;
    unawaited(reload());
    await _open(chat);
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    final chats = _chats ?? const <PersistentChat>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _enter,
          icon: const Icon(Icons.forum_outlined),
          label: const Text('Вход в чат'),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
        ),
        if (chats.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Мои чаты', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          for (final c in chats)
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.forum_outlined)),
                title: Text(c.name, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  c.lastBody == null ? 'Ключ: ${c.code} · участников: ${c.members}' : '${c.lastName}: ${c.lastBody}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: c.unread > 0 ? Badge(label: Text('${c.unread}')) : null,
                onTap: () => _open(c),
              ),
            ),
        ],
      ],
    );
  }
}

/// Окно «Вход в чат»: ввести 6-значный ключ или создать новый чат.
class _EnterChatDialog extends StatefulWidget {
  const _EnterChatDialog({required this.repo});

  final ChatsRepository repo;

  @override
  State<_EnterChatDialog> createState() => _EnterChatDialogState();
}

class _EnterChatDialogState extends State<_EnterChatDialog> {
  final _code = TextEditingController();
  final _name = TextEditingController();
  bool _creating = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = RoomsRepository.normalizeCode(_code.text);
    if (code == null) {
      setState(() => _error = 'Ключ — 6 букв и цифр');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final chat = await widget.repo.join(code);
      if (!mounted) return;
      if (chat == null) {
        setState(() => _error = 'Чата с таким ключом нет');
      } else {
        Navigator.pop(context, chat);
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Придумайте название');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final chat = await widget.repo.create(name);
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: chat.inviteText));
      if (!mounted) return;
      showError(context, 'Чат создан. Ключ ${chat.code} скопирован — отправьте его друзьям');
      Navigator.pop(context, chat);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_creating ? 'Новый чат' : 'Вход в чат'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_creating)
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 60,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Название чата', border: OutlineInputBorder()),
              onSubmitted: (_) => _create(),
            )
          else
            TextField(
              controller: _code,
              autofocus: true,
              maxLength: 6,
              textCapitalization: TextCapitalization.characters,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(letterSpacing: 6),
              decoration: const InputDecoration(labelText: 'Ключ чата', border: OutlineInputBorder()),
              onSubmitted: (_) => _join(),
            ),
          if (_error != null)
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 4),
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _creating = !_creating;
                      _error = null;
                    }),
            child: Text(_creating ? 'У меня есть ключ' : 'Создать новый чат'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: _busy ? null : (_creating ? _create : _join),
          child: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_creating ? 'Создать' : 'Войти'),
        ),
      ],
    );
  }
}
