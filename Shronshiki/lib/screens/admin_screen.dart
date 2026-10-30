import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/admin.dart';
import '../services/chats.dart';
import '../widgets/chat_bubble.dart';
import 'errors.dart';

/// Админ-панель (только для администраторов): все комнаты, чаты и аккаунты.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Админ-панель'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [Tab(text: 'Комнаты'), Tab(text: 'Чаты'), Tab(text: 'Аккаунты'), Tab(text: 'Гости')],
          ),
        ),
        body: const TabBarView(
          children: [_RoomsTab(), _ChatsTab(), _UsersTab(guests: false), _UsersTab(guests: true)],
        ),
      ),
    );
  }
}

AdminRepository get _repo => AdminRepository(AppState.instance.db);

/// Выполняет действие и показывает ошибку или [done].
Future<bool> _run(BuildContext context, Future<void> Function() action, String done) async {
  try {
    await action();
    if (context.mounted) showError(context, done);
    return true;
  } catch (e) {
    if (context.mounted) showError(context, describeError(e));
    return false;
  }
}

Future<String?> _ask(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? hint,
  bool secret = false,
  bool upper = false,
}) {
  final text = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: text,
        autofocus: true,
        obscureText: secret,
        textCapitalization: upper ? TextCapitalization.characters : TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label, helperText: hint, helperMaxLines: 3, border: const OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Готово')),
      ],
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String text, {String action = 'Удалить'}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Сменить код комнаты или ключ чата: вручную или случайный.
Future<String?> _askCode(BuildContext context, String what, String current) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Сменить $what ($current)'),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(context, 'random'), child: const Text('Новый случайный')),
        SimpleDialogOption(onPressed: () => Navigator.pop(context, 'manual'), child: const Text('Вписать свой')),
      ],
    ),
  );
  if (choice == 'random') return '';
  if (choice != 'manual' || !context.mounted) return null;
  final code = await _ask(
    context,
    title: 'Новый $what',
    label: '6 символов',
    upper: true,
    hint: 'Латинские буквы без I и O, цифры 2–9',
  );
  final v = code?.trim().toUpperCase();
  return v == null || v.isEmpty ? null : v;
}

String _date(DateTime? d) {
  if (d == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Общая заготовка вкладки: загрузка, поиск, обновление потягиванием.
abstract class _ListTabState<W extends StatefulWidget, T> extends State<W> with AutomaticKeepAliveClientMixin {
  List<T>? _items;
  String? _error;
  String _query = '';

  Future<List<T>> load();
  bool matches(T item, String query);
  Widget tile(BuildContext context, T item);
  Widget? header(BuildContext context) => null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  Future<void> reload() async {
    try {
      final items = await load();
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final items = _items;
    final q = _query.trim().toLowerCase();
    final shown = items?.where((i) => q.isEmpty || matches(i, q)).toList();
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Поиск',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          ?header(context),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!, textAlign: TextAlign.center))
          else if (shown == null)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
          else if (shown.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('Пусто')))
          else ...[
            Text('Всего: ${shown.length}', style: Theme.of(context).textTheme.bodySmall),
            for (final item in shown) tile(context, item),
          ],
        ],
      ),
    );
  }
}

class _RoomsTab extends StatefulWidget {
  const _RoomsTab();

  @override
  State<_RoomsTab> createState() => _RoomsTabState();
}

class _RoomsTabState extends _ListTabState<_RoomsTab, AdminRoom> {
  @override
  Future<List<AdminRoom>> load() => _repo.rooms();

  @override
  bool matches(AdminRoom r, String q) =>
      '${r.name} ${r.code} ${r.owner} ${r.ownerEmail ?? ''}'.toLowerCase().contains(q);

  @override
  Widget tile(BuildContext context, AdminRoom r) => Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.headphones)),
          title: Text(r.name),
          subtitle: Text('Код ${r.code} · владелец ${r.owner}${r.online > 0 ? ' · сейчас в комнате: ${r.online}' : ''}'),
          onTap: () => _actions(r),
        ),
      );

  Future<void> _actions(AdminRoom r) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(r.name), subtitle: Text('Код ${r.code} · ${r.ownerEmail ?? r.owner}')),
          ListTile(leading: const Icon(Icons.edit), title: const Text('Переименовать'), onTap: () => Navigator.pop(context, 'rename')),
          ListTile(leading: const Icon(Icons.pin), title: const Text('Сменить код'), onTap: () => Navigator.pop(context, 'code')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: const Text('Удалить комнату'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    var changed = false;
    switch (action) {
      case 'rename':
        final name = await _ask(context, title: 'Название комнаты', label: 'Название', initial: r.name);
        if (name != null && name.trim().isNotEmpty && mounted) {
          changed = await _run(context, () => _repo.updateRoom(r.id, name: name), 'Переименовано');
        }
      case 'code':
        final code = await _askCode(context, 'код', r.code);
        if (code != null && mounted) changed = await _run(context, () => _repo.updateRoom(r.id, code: code), 'Код изменён');
      case 'delete':
        if (await _confirm(context, 'Удалить «${r.name}»?', 'Комната исчезнет у владельца, войти по коду будет нельзя.') &&
            mounted) {
          changed = await _run(context, () => _repo.deleteRoom(r.id), 'Комната удалена');
        }
    }
    if (changed) unawaited(reload());
  }
}

class _ChatsTab extends StatefulWidget {
  const _ChatsTab();

  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends _ListTabState<_ChatsTab, AdminChat> {
  @override
  Future<List<AdminChat>> load() => _repo.chats();

  @override
  bool matches(AdminChat c, String q) => '${c.name} ${c.code} ${c.owner}'.toLowerCase().contains(q);

  @override
  Widget tile(BuildContext context, AdminChat c) => Card(
        child: ListTile(
          leading: const CircleAvatar(child: Icon(Icons.forum_outlined)),
          title: Text(c.name),
          subtitle: Text('Ключ ${c.code} · участников ${c.members} · сообщений ${c.messages}'),
          onTap: () => _actions(c),
        ),
      );

  Future<void> _actions(AdminChat c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(c.name), subtitle: Text('Ключ ${c.code} · создал ${c.owner}')),
          ListTile(leading: const Icon(Icons.visibility_outlined), title: const Text('Читать переписку'), onTap: () => Navigator.pop(context, 'read')),
          ListTile(leading: const Icon(Icons.edit), title: const Text('Переименовать'), onTap: () => Navigator.pop(context, 'rename')),
          ListTile(leading: const Icon(Icons.key), title: const Text('Сменить ключ'), onTap: () => Navigator.pop(context, 'code')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: const Text('Удалить чат'),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    var changed = false;
    switch (action) {
      case 'read':
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _AdminChatView(chat: c)));
        changed = true;
      case 'rename':
        final name = await _ask(context, title: 'Название чата', label: 'Название', initial: c.name);
        if (name != null && name.trim().isNotEmpty && mounted) {
          changed = await _run(context, () => _repo.updateChat(c.id, name: name), 'Переименовано');
        }
      case 'code':
        final code = await _askCode(context, 'ключ', c.code);
        if (code != null && mounted) changed = await _run(context, () => _repo.updateChat(c.id, code: code), 'Ключ изменён');
      case 'delete':
        if (await _confirm(context, 'Удалить «${c.name}»?', 'Вся переписка удалится у всех участников.') && mounted) {
          changed = await _run(context, () => _repo.deleteChat(c.id), 'Чат удалён');
        }
    }
    if (changed) unawaited(reload());
  }
}

/// Переписка чата для администратора: только чтение и удаление сообщений.
class _AdminChatView extends StatefulWidget {
  const _AdminChatView({required this.chat});

  final AdminChat chat;

  @override
  State<_AdminChatView> createState() => _AdminChatViewState();
}

class _AdminChatViewState extends State<_AdminChatView> {
  final _messages = <PersistentMessage>[];
  bool _loading = true;
  bool _noOlder = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool older = false}) async {
    try {
      final batch = await _repo.chatMessages(widget.chat.id, before: older && _messages.isNotEmpty ? _messages.first.id : null);
      if (!mounted) return;
      setState(() {
        if (older) {
          _messages.insertAll(0, batch);
          _noOlder = batch.length < 50;
        } else {
          _messages
            ..clear()
            ..addAll(batch);
          _noOlder = batch.length < 100;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  Future<void> _delete(PersistentMessage m) async {
    if (!await _confirm(context, 'Удалить сообщение?', '${m.name}: ${m.body}')) return;
    if (!mounted) return;
    if (await _run(context, () => _repo.deleteMessage(m.id), 'Сообщение удалено')) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.chat.name),
          Text('Только чтение · удерживайте сообщение, чтобы удалить', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : _messages.isEmpty
                  ? const Center(child: Text('Сообщений нет'))
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length + (_noOlder ? 0 : 1),
                      itemBuilder: (context, i) {
                        if (i == _messages.length) {
                          return TextButton(onPressed: () => _load(older: true), child: const Text('Показать раньше'));
                        }
                        final index = _messages.length - 1 - i;
                        final m = _messages[index];
                        final previous = index > 0 ? _messages[index - 1] : null;
                        return GestureDetector(
                          onLongPress: () => _delete(m),
                          child: ChatBubble(
                            name: m.name,
                            body: m.body,
                            at: m.at,
                            mine: false,
                            showName: previous == null || previous.userId != m.userId,
                          ),
                        );
                      },
                    ),
    );
  }
}

class _UsersTab extends StatefulWidget {
  const _UsersTab({required this.guests});

  final bool guests;

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends _ListTabState<_UsersTab, AdminUser> {
  @override
  Future<List<AdminUser>> load() => _repo.users(guests: widget.guests);

  @override
  bool matches(AdminUser u, String q) => '${u.name} ${u.email ?? ''}'.toLowerCase().contains(q);

  @override
  Widget? header(BuildContext context) => widget.guests
      ? Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('Удалить гостей, не заходивших 30 дней'),
            onPressed: _cleanGuests,
          ),
        )
      : null;

  Future<void> _cleanGuests() async {
    if (!await _confirm(context, 'Удалить старых гостей?',
        'Гостевые аккаунты, не заходившие больше 30 дней, удалятся. Их сообщения в чатах останутся.')) {
      return;
    }
    try {
      final n = await _repo.deleteOldGuests(30);
      if (mounted) showError(context, 'Удалено гостей: $n');
      unawaited(reload());
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  @override
  Widget tile(BuildContext context, AdminUser u) {
    final me = AppState.instance.db.auth.currentUser?.id == u.id;
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Icon(u.admin ? Icons.shield_outlined : (u.guest ? Icons.person_outline : Icons.person))),
        title: Text('${u.name}${me ? ' (вы)' : ''}${u.admin ? ' · админ' : ''}'),
        subtitle: Text([
          if (u.email != null) u.email!,
          'вход: ${_date(u.lastSignIn ?? u.created)}',
          if (u.rooms > 0) 'комнат: ${u.rooms}',
        ].join(' · ')),
        onTap: () => _actions(u, me),
      ),
    );
  }

  Future<void> _actions(AdminUser u, bool me) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(u.name),
            subtitle: Text('${u.email ?? 'гость'} · зарегистрирован ${_date(u.created)}'),
          ),
          ListTile(leading: const Icon(Icons.edit), title: const Text('Сменить имя'), onTap: () => Navigator.pop(context, 'rename')),
          if (!u.guest)
            ListTile(leading: const Icon(Icons.password), title: const Text('Задать новый пароль'), onTap: () => Navigator.pop(context, 'password')),
          if (!u.guest && !me)
            ListTile(
              leading: Icon(u.admin ? Icons.remove_moderator_outlined : Icons.add_moderator_outlined),
              title: Text(u.admin ? 'Забрать права админа' : 'Сделать админом'),
              onTap: () => Navigator.pop(context, 'admin'),
            ),
          if (!me)
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: const Text('Удалить аккаунт'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    var changed = false;
    switch (action) {
      case 'rename':
        final name = await _ask(context, title: 'Имя пользователя', label: 'Имя', initial: u.name);
        if (name != null && name.trim().isNotEmpty && mounted) {
          changed = await _run(context, () => _repo.renameUser(u.id, name), 'Имя изменено');
        }
      case 'password':
        final password = await _ask(
          context,
          title: 'Новый пароль для ${u.name}',
          label: 'Пароль',
          hint: 'Не меньше 6 символов. Сообщите его пользователю — старый перестанет подходить.',
        );
        if (password != null && password.isNotEmpty && mounted) {
          changed = await _run(context, () => _repo.setPassword(u.id, password), 'Пароль изменён');
        }
      case 'admin':
        changed = await _run(context, () => _repo.setAdmin(u.id, !u.admin), u.admin ? 'Права забраны' : 'Теперь админ');
      case 'delete':
        if (await _confirm(
              context,
              'Удалить аккаунт ${u.name}?',
              'Его комнаты и чаты перейдут вам, сообщения в чатах останутся с подписью «Удалённый пользователь». '
                  'Отменить нельзя.',
            ) &&
            mounted) {
          changed = await _run(context, () => _repo.deleteUser(u.id), 'Аккаунт удалён');
        }
    }
    if (changed) unawaited(reload());
  }
}
