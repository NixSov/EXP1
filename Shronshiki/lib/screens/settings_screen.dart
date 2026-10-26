import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../services/background_call.dart';
import 'errors.dart';
import 'setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppState get _app => AppState.instance;

  Future<void> _changeName() async {
    final user = _app.db.auth.currentUser!;
    final controller = TextEditingController(text: user.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ваше имя'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
    if (name == null || name.isEmpty) return;
    try {
      await _app.db.auth.updateUser(UserAttributes(data: {'display_name': name}));
      await _app.db.from('profiles').update({'display_name': name}).eq('id', user.id);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    }
  }

  Future<void> _signOut() async {
    Navigator.of(context).popUntil((route) => route.isFirst);
    await _app.db.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final user = _app.db.auth.currentUser;
    final settings = _app.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            if (user != null) ...[
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(user.displayName),
                subtitle: Text(user.isAnonymous ? 'Гость' : (user.email ?? '')),
                trailing: const Icon(Icons.edit_outlined),
                onTap: _changeName,
              ),
              const Divider(),
            ],
            const _Header('Звук'),
            SwitchListTile(
              secondary: const Icon(Icons.noise_aware),
              title: const Text('Шумоподавление'),
              subtitle: const Text('Применяется при следующем входе в комнату'),
              value: settings.noiseSuppression,
              onChanged: (v) => settings.noiseSuppression = v,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.volume_up_outlined),
              title: const Text('Громкая связь по умолчанию'),
              subtitle: const Text('Иначе звук идёт в наушники или динамик у уха'),
              value: settings.speakerByDefault,
              onChanged: (v) => settings.speakerByDefault = v,
            ),
            if (BackgroundCall.supported)
              ListTile(
                leading: const Icon(Icons.battery_saver_outlined),
                title: const Text('Не ограничивать в фоне'),
                subtitle: const Text(
                    'Если звонок обрывается при выключенном экране — отключите для приложения '
                    'оптимизацию батареи'),
                onTap: () => FlutterForegroundTask.requestIgnoreBatteryOptimization(),
              ),
            const Divider(),
            const _Header('Сервер'),
            ExpansionTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Supabase и TURN'),
              childrenPadding: const EdgeInsets.all(16),
              children: [
                ServerConfigForm(
                  submitLabel: 'Сохранить',
                  onSaved: () async {
                    if (context.mounted) {
                      showError(context, 'Сохранено. Новый адрес Supabase применится после перезапуска.');
                    }
                  },
                ),
              ],
            ),
            const Divider(),
            if (user != null)
              ListTile(
                leading: const Icon(Icons.logout),
                title: Text(user.isAnonymous ? 'Выйти из гостевого режима' : 'Выйти из аккаунта'),
                onTap: _signOut,
              ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                )),
      );
}
