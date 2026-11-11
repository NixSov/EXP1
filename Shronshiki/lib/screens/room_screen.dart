import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

import '../services/call_controller.dart';
import '../services/call_session.dart';
import 'errors.dart';
import 'settings_screen.dart';
import 'chat_screen.dart';
import '../app_state.dart';
import '../services/chats.dart';
import '../widgets/room_chat_sheet.dart';
import '../widgets/screen_share.dart';

/// Голосовая комната. Экран только показывает звонок из [CallSession]:
/// уйти с него назад или в настройки можно, не выходя из комнаты.
class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.call});

  final CallController call;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  bool _pinned = false;
  bool _pinControls = false;
  Timer? _pinTimer;
  void _showPinControls() {
    _pinTimer?.cancel();
    setState(() => _pinControls = true);
    _pinTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _pinControls = false);
    });
  }

  CallController get _call => widget.call;

  @override
  void initState() {
    super.initState();
    _call.addListener(_onCallChanged);
  }

  void _onCallChanged() {
    if (!mounted) return;
    if (_call.screenSharer == null || _call.screenSharer!.isLocal) {
      _pinned = false;
    }
    if (_call.status == CallStatus.ended) {
      // Вышли (в том числе кнопкой в уведомлении) — возвращаемся к списку комнат.
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _pinTimer?.cancel();
    _call.removeListener(_onCallChanged);
    // Ошибка или «комната заполнена» — звонок больше не нужен.
    CallSession.dismissIfFinished();
    super.dispose();
  }

  void _copyInvite() {
    Clipboard.setData(ClipboardData(text: _call.room.inviteText));
    showError(context, 'Приглашение скопировано');
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final inCall = _call.isActive;
    return Scaffold(
      appBar: _pinned && _call.screenSharer != null
          ? null
          : AppBar(
              leading: IconButton(
                tooltip: inCall
                    ? 'К списку комнат (звонок продолжится)'
                    : 'Назад',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_call.room.name, overflow: TextOverflow.ellipsis),
                  Text(
                    'Код: ${_call.room.code}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: [
                if (_call.status == CallStatus.inRoom)
                  IconButton(
                    tooltip: 'Обновить подключение',
                    icon: const Icon(Icons.sync),
                    onPressed: _call.reconnect,
                  ),
                IconButton(
                  tooltip: 'Пригласить',
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  onPressed: _copyInvite,
                ),
                IconButton(
                  tooltip: 'Настройки',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openSettings,
                ),
              ],
            ),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    switch (_call.status) {
      case CallStatus.connecting:
        return const _Message(
          icon: null,
          title: 'Подключение…',
          text: 'Входим в комнату',
        );
      case CallStatus.full:
        return _Message(
          icon: Icons.group_off_outlined,
          title: 'Комната заполнена',
          text:
              'В комнате уже ${_call.room.maxParticipants} участника — это максимум. '
              'Попробуйте позже.',
          action: _retryOrBack(context),
        );
      case CallStatus.failed:
        return _Message(
          icon: Icons.error_outline,
          title: 'Не получилось войти',
          text: _call.errorMessage ?? 'Неизвестная ошибка',
          action: _retryOrBack(context),
        );
      case CallStatus.ended:
        return const SizedBox.shrink();
      case CallStatus.inRoom:
        return _inRoom(context);
    }
  }

  Widget _retryOrBack(BuildContext context) => Wrap(
    spacing: 12,
    runSpacing: 12,
    alignment: WrapAlignment.center,
    children: [
      OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Назад'),
      ),
      FilledButton.icon(
        onPressed: _call.reconnect,
        icon: const Icon(Icons.refresh),
        label: const Text('Повторить'),
      ),
    ],
  );

  /// Список устройств (как в SaluteJazz — по стрелочке у кнопки).
  Future<void> _pickDevice({required bool input}) async {
    final title = input ? 'Микрофон' : 'Вывод звука';
    await _call.refreshDevices();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: _call,
          builder: (context, _) {
            final list = input ? _call.inputs : _call.outputs;
            final current = input ? _call.inputId : _call.outputId;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (list.isEmpty)
                  const ListTile(title: Text('Нет доступных устройств')),
                for (final d in list)
                  ListTile(
                    leading: Icon(_deviceIcon(d.icon)),
                    title: Text(d.label),
                    trailing: d.id == current ? const Icon(Icons.check) : null,
                    selected: d.id == current,
                    onTap: () {
                      Navigator.pop(context);
                      input
                          ? _call.selectInput(d.id)
                          : _call.selectOutput(d.id);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            );
          },
        ),
      ),
    );
  }

  static IconData _deviceIcon(String icon) => switch (icon) {
    'speaker' => Icons.volume_up,
    'earpiece' => Icons.phone_in_talk,
    'headset' => Icons.headphones,
    'bluetooth' => Icons.bluetooth_audio,
    _ => Icons.mic,
  };

  ({IconData icon, String label}) get _outputLook {
    final current = _call.outputs
        .where((d) => d.id == _call.outputId)
        .firstOrNull;
    return switch (current?.icon) {
      'speaker' => (icon: Icons.volume_up, label: 'Динамик'),
      'earpiece' => (icon: Icons.phone_in_talk, label: 'Телефон'),
      'headset' => (icon: Icons.headphones, label: 'Наушники'),
      'bluetooth' => (icon: Icons.bluetooth_audio, label: 'Bluetooth'),
      _ => (icon: Icons.volume_up, label: 'Звук'),
    };
  }

  /// Кнопка «Экран»: выбор экрана или окна и качества, потом показ.
  Future<void> _toggleScreenShare() async {
    if (_call.sharingScreen) {
      await _call.stopScreenShare();
      return;
    }
    final other = _call.screenSharer;
    if (other != null && !other.isLocal) {
      showError(
        context,
        'Сейчас экран показывает ${other.name}. Показывать может один человек.',
      );
      return;
    }
    final choice = await pickScreenSource(context, _call);
    if (choice == null || !mounted) return;
    try {
      await _call.startScreenShare(
        choice.source,
        choice.quality,
        audio: choice.audio,
      );
    } catch (e) {
      if (mounted) showError(context, 'Не получилось показать экран: $e');
    }
  }

  void _pickInput() => _pickDevice(input: true);

  void _pickOutput() => _pickDevice(input: false);

  Future<void> _participantOptions(Participant participant) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => ListenableBuilder(
        listenable: _call,
        builder: (context, _) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  participant.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Text('Громкость голоса для вас'),
                Slider(
                  value: _call.participantVolume(participant.peerId),
                  divisions: 100,
                  label:
                      '${(_call.participantVolume(participant.peerId) * 100).round()}%',
                  onChanged: (v) =>
                      _call.setParticipantVolume(participant.peerId, v),
                ),
                if (participant.sharingScreen) ...[
                  const Text('Громкость трансляции для вас'),
                  Slider(
                    value: _call.screenVolume,
                    divisions: 100,
                    label: '${(_call.screenVolume * 100).round()}%',
                    onChanged: _call.setScreenVolume,
                  ),
                  SwitchListTile(
                    title: const Text('Показывать и слушать трансляцию'),
                    value: !_call.screenHidden,
                    onChanged: (v) {
                      _pinned = false;
                      _call.setScreenHidden(!v);
                    },
                  ),
                ],
                TextButton.icon(
                  icon: const Icon(Icons.chat_outlined),
                  label: const Text('Написать лично'),
                  onPressed: () async {
                    Navigator.pop(sheet);
                    try {
                      final chat = await ChatsRepository(AppState.instance.db)
                          .directFromRoom(_call.room.id, participant.peerId);
                      if (mounted) {
                        await Navigator.of(this.context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ChatScreen(chat: chat),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) showError(this.context, describeError(e));
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _participantWidget(Participant p, {bool compact = false}) => InkWell(
    borderRadius: BorderRadius.circular(12),
    onTap: p.isLocal ? null : () => _participantOptions(p),
    child: compact
        ? _CompactParticipant(participant: p)
        : _ParticipantTile(participant: p),
  );

  Widget _inRoom(BuildContext context) {
    final participants = _call.participants;
    final scheme = Theme.of(context).colorScheme;
    final output = _outputLook;
    final sharer = _call.screenSharer;
    final watching = sharer != null && !sharer.isLocal && !_call.screenHidden;
    final desktop = MediaQuery.sizeOf(context).width >= 800;
    if (_pinned && watching) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              setState(() => _pinned = false),
        },
        child: Focus(
          autofocus: true,
          child: MouseRegion(
            onHover: (_) => _showPinControls(),
            child: GestureDetector(
              onTap: _showPinControls,
              onDoubleTap: () => setState(() => _pinned = false),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ScreenView(call: _call, sharer: sharer, minimal: true),
                  if (_pinControls)
                    Positioned(
                      right: 12,
                      top: 12,
                      child: IconButton(
                        tooltip: 'Открепить (Esc)',
                        onPressed: () => setState(() => _pinned = false),
                        icon: const Icon(Icons.push_pin_outlined),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        if (sharer != null && !sharer.isLocal)
          ListTile(
            dense: true,
            leading: Icon(
              _call.screenHidden ? Icons.visibility_off : Icons.screen_share,
            ),
            title: Text(
              _call.screenHidden
                  ? 'Трансляция скрыта и выключена для вас'
                  : 'Трансляция: ${sharer.name}',
            ),
            onTap: () => _participantOptions(sharer),
            trailing: IconButton(
              tooltip: _call.screenHidden
                  ? 'Включить трансляцию'
                  : 'Отключить трансляцию для себя',
              icon: Icon(
                _call.screenHidden ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () {
                _pinned = false;
                _call.setScreenHidden(!_call.screenHidden);
              },
            ),
          ),
        if (_call.serverLost)
          Container(
            width: double.infinity,
            color: scheme.errorContainer,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              'Нет связи с сервером. Разговор продолжается напрямую, '
              'но новые участники не подключатся, пока связь не вернётся.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        if (_call.sharingScreen)
          Container(
            width: double.infinity,
            color: scheme.primaryContainer,
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Icon(Icons.screen_share, color: scheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Вы показываете экран (${_call.screenQuality.label.toLowerCase()})'
                    '${_call.turnPeers > 0 ? '. Через TURN: ${_call.turnPeers}' : ''}',
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
                ),
                TextButton(
                  onPressed: _call.stopScreenShare,
                  child: const Text('Остановить'),
                ),
              ],
            ),
          ),
        if (watching) ...[
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: ScreenView(
                key: ValueKey(sharer.peerId),
                call: _call,
                sharer: sharer,
                onPin: () => setState(() => _pinned = true),
              ),
            ),
          ),
          SizedBox(
            height: 92,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final p in participants)
                  _participantWidget(p, compact: true),
              ],
            ),
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Text(
                  'Участники: ${participants.length} из ${_call.room.maxParticipants}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
          ),
          if (desktop)
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final p in participants)
                          SizedBox(
                            width: 180,
                            height: 200,
                            child: _participantWidget(p),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [for (final p in participants) _participantWidget(p)],
              ),
            ),
        ],
        if (participants.length == 1)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Вы пока одни. Нажмите значок приглашения вверху и отправьте код друзьям.',
              textAlign: TextAlign.center,
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(
            vertical: desktop ? 8 : 20,
            horizontal: 8,
          ),
          child: Wrap(
            alignment: WrapAlignment.spaceEvenly,
            spacing: 8,
            runSpacing: 12,
            children: [
              _ControlButton(
                icon: _call.muted ? Icons.mic_off : Icons.mic,
                label: _call.muted ? 'Микр. выкл.' : 'Микрофон',
                active: !_call.muted,
                onPressed: _call.toggleMute,
                onMore: _pickInput,
              ),
              _ControlButton(
                icon: output.icon,
                label: output.label,
                active: _call.speakerOn,
                onPressed: _call.canSwitchSpeaker
                    ? _call.toggleSpeaker
                    : _pickOutput,
                onMore: _pickOutput,
              ),
              _ControlButton(
                icon: Icons.chat_bubble_outline,
                label: 'Чат',
                active: false,
                badge: _call.unreadChat,
                onPressed: () => showRoomChat(context, _call),
              ),
              if (CallController.canShareScreen)
                _ControlButton(
                  icon: _call.sharingScreen
                      ? Icons.stop_screen_share
                      : Icons.screen_share,
                  label: _call.sharingScreen ? 'Стоп показ' : 'Экран',
                  active: _call.sharingScreen,
                  onPressed: _toggleScreenShare,
                ),
              _ControlButton(
                icon: Icons.call_end,
                label: 'Выйти',
                active: true,
                color: scheme.error,
                foreground: scheme.onError,
                onPressed: CallSession.leave,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant});

  final Participant participant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = participant;
    final initial = p.name.isEmpty
        ? '?'
        : p.name.characters.first.toUpperCase();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: p.speaking
                      ? Colors.greenAccent.shade400
                      : Colors.transparent,
                  width: 4,
                ),
              ),
              child: CircleAvatar(
                radius: 34,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  initial,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (p.muted) ...[
                  Icon(Icons.mic_off, size: 16, color: scheme.error),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    p.isLocal ? '${p.name} (вы)' : p.name,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (p.sharingScreen)
              Text(
                'показывает экран',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.primary),
              ),
            if (p.viaTurn)
              Text('через TURN', style: Theme.of(context).textTheme.bodySmall),
            if (!p.connected)
              Text(
                switch (p.connection) {
                  null || RTCPeerConnectionState.RTCPeerConnectionStateNew =>
                    'ждём ответа…',
                  RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
                    'ищем путь…',
                  RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
                    'связь прервалась…',
                  RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
                    'нет прямого пути — нужен TURN',
                  _ => 'подключение…',
                },
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

/// Участник в узкой полосе под демонстрацией экрана.
class _CompactParticipant extends StatelessWidget {
  const _CompactParticipant({required this.participant});

  final Participant participant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = participant;
    final initial = p.name.isEmpty
        ? '?'
        : p.name.characters.first.toUpperCase();
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: p.speaking
                    ? Colors.greenAccent.shade400
                    : Colors.transparent,
                width: 3,
              ),
            ),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primaryContainer,
              child: p.muted
                  ? Icon(Icons.mic_off, size: 18, color: scheme.error)
                  : Text(initial),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            p.isLocal ? 'Вы' : p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
    this.onMore,
    this.color,
    this.foreground,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  /// Стрелочка рядом с кнопкой — список устройств.
  final VoidCallback? onMore;
  final Color? color;
  final Color? foreground;

  /// Число на кнопке (например, непрочитанные сообщения); 0 — не показывать.
  final int badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width >= 800;
    final bg =
        color ?? (active ? scheme.primary : scheme.surfaceContainerHighest);
    final fg = foreground ?? (active ? scheme.onPrimary : scheme.onSurface);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: onPressed,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 10 : 16,
                    compact ? 10 : 16,
                    onMore == null ? (compact ? 10 : 16) : 8,
                    compact ? 10 : 16,
                  ),
                  child: Badge(
                    isLabelVisible: badge > 0,
                    label: Text('$badge'),
                    child: Icon(icon, size: compact ? 20 : 28, color: fg),
                  ),
                ),
              ),
              if (onMore != null)
                InkWell(
                  onTap: onMore,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      0,
                      compact ? 10 : 16,
                      10,
                      compact ? 10 : 16,
                    ),
                    child: Icon(Icons.keyboard_arrow_up, size: 22, color: fg),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData? icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary)
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
