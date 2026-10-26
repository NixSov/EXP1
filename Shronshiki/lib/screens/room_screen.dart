import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../services/background_call.dart';
import '../services/call_controller.dart';
import '../services/rooms.dart';
import 'errors.dart';

/// Голосовая комната.
class RoomScreen extends StatefulWidget {
  const RoomScreen({super.key, required this.room, required this.displayName});

  final Room room;
  final String displayName;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late final CallController _call;
  CallStatus? _lastStatus;

  @override
  void initState() {
    super.initState();
    final app = AppState.instance;
    _call = CallController(
      room: widget.room,
      displayName: widget.displayName,
      config: app.config,
      settings: app.settings,
    )..addListener(_onCallChanged);
    _start();
  }

  Future<void> _start() async {
    // Доступ к микрофону flutter_webrtc запрашивает сам при getUserMedia.
    await _call.start();
  }

  void _onCallChanged() {
    final status = _call.status;
    if (status != _lastStatus) {
      _lastStatus = status;
      if (status == CallStatus.inRoom) {
        BackgroundCall.start(roomName: widget.room.name, onHangUp: _leave);
      } else if (status != CallStatus.connecting) {
        BackgroundCall.stop();
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _leave() async {
    await _call.hangUp();
    await BackgroundCall.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _call.removeListener(_onCallChanged);
    _call.dispose();
    BackgroundCall.stop();
    super.dispose();
  }

  void _copyInvite() {
    Clipboard.setData(ClipboardData(text: widget.room.inviteText));
    showError(context, 'Приглашение скопировано');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _call.status != CallStatus.inRoom,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.room.name, overflow: TextOverflow.ellipsis),
              Text('Код: ${widget.room.code}', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Пригласить',
              icon: const Icon(Icons.person_add_alt_1_outlined),
              onPressed: _copyInvite,
            ),
          ],
        ),
        body: SafeArea(child: _body(context)),
      ),
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
          text: 'В комнате уже ${widget.room.maxParticipants} участника — это максимум. '
              'Попробуйте позже.',
          action: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Назад')),
        );
      case CallStatus.failed:
        return _Message(
          icon: Icons.error_outline,
          title: 'Не получилось войти',
          text: _call.errorMessage ?? 'Неизвестная ошибка',
          action: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Назад')),
        );
      case CallStatus.ended:
        return const SizedBox.shrink();
      case CallStatus.inRoom:
        return _inRoom(context);
    }
  }

  Widget _inRoom(BuildContext context) {
    final participants = _call.participants;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Text(
                'Участники: ${participants.length} из ${widget.room.maxParticipants}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.count(
            padding: const EdgeInsets.all(16),
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [for (final p in participants) _ParticipantTile(participant: p)],
          ),
        ),
        if (participants.length == 1)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Вы пока одни. Нажмите значок приглашения вверху и отправьте код друзьям.',
              textAlign: TextAlign.center,
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ControlButton(
                icon: _call.muted ? Icons.mic_off : Icons.mic,
                label: _call.muted ? 'Микрофон выкл.' : 'Микрофон',
                active: !_call.muted,
                onPressed: _call.toggleMute,
              ),
              if (_call.canSwitchSpeaker)
                _ControlButton(
                  icon: _call.speakerOn ? Icons.volume_up : Icons.headphones,
                  label: _call.speakerOn ? 'Динамик' : 'Наушники',
                  active: _call.speakerOn,
                  onPressed: _call.toggleSpeaker,
                ),
              _ControlButton(
                icon: Icons.call_end,
                label: 'Выйти',
                active: true,
                color: scheme.error,
                foreground: scheme.onError,
                onPressed: _leave,
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
    final initial = p.name.isEmpty ? '?' : p.name.characters.first.toUpperCase();
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
                  color: p.speaking ? Colors.greenAccent.shade400 : Colors.transparent,
                  width: 4,
                ),
              ),
              child: CircleAvatar(
                radius: 34,
                backgroundColor: scheme.primaryContainer,
                child: Text(initial, style: Theme.of(context).textTheme.headlineMedium),
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
            if (!p.connected)
              Text('подключение…', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
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
    this.color,
    this.foreground,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;
  final Color? color;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          iconSize: 30,
          padding: const EdgeInsets.all(16),
          style: IconButton.styleFrom(
            backgroundColor: color ?? (active ? scheme.primary : scheme.surfaceContainerHighest),
            foregroundColor: foreground ?? (active ? scheme.onPrimary : scheme.onSurface),
          ),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.title, required this.text, this.action});

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
            Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
