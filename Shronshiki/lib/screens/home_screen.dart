import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/rooms.dart';
import '../services/call_controller.dart';
import '../services/call_session.dart';
import '../services/ice_servers.dart';
import '../services/mentions.dart';
import '../services/updater.dart';
import '../widgets/active_call_banner.dart';
import '../widgets/app_update.dart';
import 'errors.dart';
import 'room_screen.dart';
import 'settings_screen.dart';

/// Главный экран: вход по коду и «Мои комнаты».
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _code = TextEditingController();
  List<Room>? _rooms;
  String? _roomsError;
  bool _joining = false;
  bool _inRoom = false;

  AppState get _app => AppState.instance;
  bool get _isGuest => _app.db.auth.currentUser?.isAnonymous ?? true;

  @override
  void initState() {
    super.initState();
    if (!_isGuest) _loadRooms();
    _app.pendingJoinCode.addListener(_onInvite);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
    // Упоминания в чатах комнат, пока приложение запущено.
    MentionWatcher.start();
    unawaited(ServerIce.refresh(_app.db));
    // Новая версия на GitHub — покажем плашку. Ошибки сети здесь не важны.
    if (Updater.supported && Updater.available.value == null) {
      Updater.check().catchError((Object e) {
        debugPrint('update check failed: $e');
        return null;
      });
    }
  }

  @override
  void dispose() {
    _app.pendingJoinCode.removeListener(_onInvite);
    MentionWatcher.stop();
    _code.dispose();
    super.dispose();
  }

  void _onInvite() {
    final code = _app.pendingJoinCode.value;
    if (code == null || !mounted || _inRoom) return;
    _app.pendingJoinCode.value = null;
    _code.text = code;
    _join(code);
  }

  Future<void> _loadRooms() async {
    try {
      final rooms = await _app.rooms.myRooms();
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _roomsError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _roomsError = describeError(e));
    }
  }

  Future<void> _join(String input) async {
    final code = RoomsRepository.normalizeCode(input);
    if (code == null) {
      showError(context, 'Код комнаты — 6 букв и цифр');
      return;
    }
    if (_joining) return;
    setState(() => _joining = true);
    try {
      final room = await _app.rooms.findByCode(code);
      if (!mounted) return;
      if (room == null) {
        showError(context, 'Комната с кодом $code не найдена');
        return;
      }
      await _openRoom(room);
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _openRoom(Room room) async {
    final active = CallSession.current.value;
    if (active != null && active.isActive && active.room.id != room.id) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Перейти в другую комнату?'),
          content: Text('Вы выйдете из комнаты «${active.room.name}».'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Перейти')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final user = _app.db.auth.currentUser!;
    final call = CallSession.join(room, user.displayName);
    await _showCall(call);
  }

  Future<void> _showCall(CallController call) async {
    _inRoom = true;
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RoomScreen(call: call),
      ));
    } finally {
      _inRoom = false;
    }
  }

  Future<void> _createRoom() async {
    final name = await _askName(title: 'Новая комната', initial: '');
    if (name == null) return;
    try {
      final room = await _app.rooms.create(name);
      await _loadRooms();
      if (mounted) await _shareRoom(room);
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  Future<void> _renameRoom(Room room) async {
    final name = await _askName(title: 'Переименовать', initial: room.name);
    if (name == null) return;
    try {
      await _app.rooms.rename(room.id, name);
      await _loadRooms();
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  Future<void> _deleteRoom(Room room) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить комнату?'),
        content: Text('«${room.name}» и её код ${room.code} перестанут работать.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _app.rooms.delete(room.id);
      await _loadRooms();
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  Future<void> _shareRoom(Room room) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(room.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Код для входа'),
            const SizedBox(height: 8),
            SelectableText(
              room.code,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(letterSpacing: 6),
            ),
            const SizedBox(height: 8),
            Text(room.inviteLink, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: room.inviteText));
              Navigator.pop(context);
              showError(this.context, 'Приглашение скопировано');
            },
            child: const Text('Скопировать приглашение'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Готово')),
        ],
      ),
    );
  }

  Future<String?> _askName({required String title, required String initial}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) {
        void submit() {
          final text = controller.text.trim();
          if (text.isNotEmpty) Navigator.pop(context, text);
        }

        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Название'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            FilledButton(onPressed: submit, child: const Text('Сохранить')),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final user = _app.db.auth.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shronshiki'),
        actions: [
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ).then((_) => setState(() {})),
          ),
        ],
      ),
      floatingActionButton: _isGuest
          ? null
          : FloatingActionButton.extended(
              onPressed: _createRoom,
              icon: const Icon(Icons.add),
              label: const Text('Создать комнату'),
            ),
      body: RefreshIndicator(
        onRefresh: _isGuest ? () async {} : _loadRooms,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            Text('Привет, ${user.displayName}!', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ActiveCallBanner(onOpen: _showCall),
            const UpdateBanner(),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Войти по коду', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _code,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              hintText: 'Код или ссылка',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: _join,
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _joining ? null : () => _join(_code.text),
                          child: _joining
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Войти'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_isGuest) ..._guestInfo(context) else ..._roomsList(context),
          ],
        ),
      ),
    );
  }

  List<Widget> _guestInfo(BuildContext context) => [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Вы вошли как гость. Чтобы создавать свои комнаты, '
                    'зарегистрируйтесь.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    await CallSession.leave();
                    await _app.db.auth.signOut();
                  },
                  child: const Text('Войти или зарегистрироваться'),
                ),
              ],
            ),
          ),
        ),
      ];

  List<Widget> _roomsList(BuildContext context) {
    final rooms = _rooms;
    return [
      Text('Мои комнаты', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (_roomsError != null)
        ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text(_roomsError!),
          trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: _loadRooms),
        )
      else if (rooms == null)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (rooms.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('У вас пока нет комнат. Нажмите «Создать комнату».'),
        )
      else
        for (final room in rooms)
          Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.headset_mic_outlined)),
              title: Text(room.name),
              subtitle: Text('Код: ${room.code}'),
              onTap: () => _openRoom(room),
              trailing: PopupMenuButton<String>(
                onSelected: (action) {
                  switch (action) {
                    case 'share':
                      _shareRoom(room);
                    case 'rename':
                      _renameRoom(room);
                    case 'delete':
                      _deleteRoom(room);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'share', child: Text('Пригласить')),
                  PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                  PopupMenuItem(value: 'delete', child: Text('Удалить')),
                ],
              ),
            ),
          ),
    ];
  }
}
