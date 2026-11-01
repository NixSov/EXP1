import 'dart:io';

import 'package:flutter/material.dart';

import '../services/call_session.dart';
import '../services/updater.dart';

/// Окно обновления: что нового, скачивание с прогрессом и установка.
Future<void> showUpdateDialog(BuildContext context, AppUpdate update) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(update: update),
    );

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.update});

  final AppUpdate update;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress;
  bool _busy = false;
  bool _handedOver = false;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      final file = await Updater.download(widget.update, (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() => _handedOver = true);
      // Звонок всё равно прервётся: приложение перезапустится в новой версии.
      await CallSession.leave();
      await Updater.install(file);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _handedOver = false;
          _error = 'Не получилось обновить: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.update;
    final inCall = CallSession.current.value?.isActive ?? false;
    final mb = u.size > 0 ? ' (${(u.size / 1048576).toStringAsFixed(0)} МБ)' : '';
    return AlertDialog(
      title: Text('Новая версия: сборка ${u.build}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (u.notes.isNotEmpty) ...[
              Text(u.notes),
              const SizedBox(height: 12),
            ],
            if (inCall && !_busy)
              Text('Звонок прервётся на время обновления.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_busy) ...[
              LinearProgressIndicator(value: _handedOver ? null : _progress),
              const SizedBox(height: 8),
              Text(_handedOver
                  ? (Platform.isAndroid
                      ? 'Подтвердите установку в окне Android.'
                      : 'Устанавливаем — программа перезапустится сама.')
                  : 'Скачиваем$mb… ${((_progress ?? 0) * 100).toStringAsFixed(0)}%'),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy && !_handedOver ? null : () => Navigator.pop(context),
          child: Text(_handedOver ? 'Закрыть' : 'Позже'),
        ),
        if (!_handedOver)
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: const Icon(Icons.system_update_alt),
            label: Text(_error == null ? 'Обновить' : 'Ещё раз'),
          ),
      ],
    );
  }
}

/// Плашка на главном экране, когда вышла новая версия.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppUpdate?>(
      valueListenable: Updater.available,
      builder: (context, update, _) {
        if (update == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Card(
          color: scheme.tertiaryContainer,
          child: ListTile(
            leading: Icon(Icons.system_update, color: scheme.onTertiaryContainer),
            title: Text('Вышла новая версия', style: TextStyle(color: scheme.onTertiaryContainer)),
            subtitle: Text('Сборка ${update.build}', style: TextStyle(color: scheme.onTertiaryContainer)),
            trailing: FilledButton(
              onPressed: () => showUpdateDialog(context, update),
              child: const Text('Обновить'),
            ),
          ),
        );
      },
    );
  }
}

/// Пункт «Обновления» в настройках.
class UpdateTile extends StatefulWidget {
  const UpdateTile({super.key});

  @override
  State<UpdateTile> createState() => _UpdateTileState();
}

class _UpdateTileState extends State<UpdateTile> {
  bool _checking = false;
  String? _status;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _status = null;
    });
    try {
      final update = await Updater.check();
      if (!mounted) return;
      if (update == null) {
        setState(() => _status = 'У вас последняя версия');
      } else {
        await showUpdateDialog(context, update);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Не удалось проверить: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const build = Updater.currentBuild;
    final version = build > 0 ? 'Версия: сборка $build' : 'Версия: собрана вручную';
    return ListTile(
      leading: const Icon(Icons.system_update_alt),
      title: const Text('Проверить обновления'),
      subtitle: Text(_status == null ? version : '$version. $_status'),
      trailing: _checking
          ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : null,
      onTap: _checking ? null : _check,
    );
  }
}
