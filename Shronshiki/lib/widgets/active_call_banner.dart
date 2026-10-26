import 'package:flutter/material.dart';

import '../services/call_controller.dart';
import '../services/call_session.dart';

/// Плашка «Вы в комнате …» на главном экране, пока идёт звонок.
class ActiveCallBanner extends StatelessWidget {
  const ActiveCallBanner({super.key, required this.onOpen});

  final void Function(CallController call) onOpen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CallController?>(
      valueListenable: CallSession.current,
      builder: (context, call, _) {
        if (call == null) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: call,
          builder: (context, _) {
            if (!call.isActive) return const SizedBox.shrink();
            final scheme = Theme.of(context).colorScheme;
            final count = call.participants.length;
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Card(
                color: scheme.primaryContainer,
                child: ListTile(
                  onTap: () => onOpen(call),
                  leading: Icon(call.muted ? Icons.mic_off : Icons.graphic_eq,
                      color: scheme.onPrimaryContainer),
                  title: Text('Вы в комнате «${call.room.name}»',
                      style: TextStyle(color: scheme.onPrimaryContainer)),
                  subtitle: Text(
                    call.status == CallStatus.connecting
                        ? 'Подключение…'
                        : 'Участников: $count'
                            '${call.unreadChat > 0 ? ' · новых сообщений: ${call.unreadChat}' : ''}'
                            ' · нажмите, чтобы вернуться',
                    style: TextStyle(color: scheme.onPrimaryContainer),
                  ),
                  trailing: IconButton(
                    tooltip: 'Выйти из комнаты',
                    icon: Icon(Icons.call_end, color: scheme.error),
                    onPressed: CallSession.leave,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
