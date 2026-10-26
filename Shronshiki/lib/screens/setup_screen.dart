import 'package:flutter/material.dart';

import '../app_state.dart';
import '../config.dart';

/// Первый запуск: адрес проекта Supabase, ключ и (необязательно) TURN.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройка сервера')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Приложение собрано без настроек сервера. Введите данные проекта '
              'Supabase (Project Settings → API). Они сохранятся только на этом устройстве.',
            ),
            const SizedBox(height: 16),
            ServerConfigForm(
              submitLabel: 'Сохранить и продолжить',
              onSaved: () async {
                await AppState.instance.initSupabase();
                onDone();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Форма настроек серверов (используется и в «Настройках»).
class ServerConfigForm extends StatefulWidget {
  const ServerConfigForm({super.key, required this.submitLabel, required this.onSaved});

  final String submitLabel;
  final Future<void> Function() onSaved;

  @override
  State<ServerConfigForm> createState() => _ServerConfigFormState();
}

class _ServerConfigFormState extends State<ServerConfigForm> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _turnUrls;
  late final TextEditingController _turnUser;
  late final TextEditingController _turnPass;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = AppState.instance.config;
    _url = TextEditingController(text: c.supabaseUrl);
    _key = TextEditingController(text: c.supabaseAnonKey);
    _turnUrls = TextEditingController(text: c.turnUrls.join(', '));
    _turnUser = TextEditingController(text: c.turnUsername);
    _turnPass = TextEditingController(text: c.turnCredential);
  }

  @override
  void dispose() {
    for (final c in [_url, _key, _turnUrls, _turnUser, _turnPass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final config = AppConfig(
      supabaseUrl: _url.text.trim().replaceAll(RegExp(r'/+$'), ''),
      supabaseAnonKey: _key.text.trim(),
      turnUrls: AppConfig.splitUrls(_turnUrls.text),
      turnUsername: _turnUser.text.trim(),
      turnCredential: _turnPass.text.trim(),
    );
    try {
      await config.save();
      AppState.instance.config = config;
      await widget.onSaved();
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось сохранить: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Project URL',
              hintText: 'https://xxxx.supabase.co',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v ?? '').trim().startsWith('https://') ? null : 'Адрес должен начинаться с https://',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _key,
            decoration: const InputDecoration(
              labelText: 'anon public key',
              border: OutlineInputBorder(),
            ),
            validator: (v) => (v ?? '').trim().length > 20 ? null : 'Вставьте ключ целиком',
          ),
          const SizedBox(height: 20),
          Text('TURN-сервер (необязательно)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text(
            'Нужен, если участники не слышат друг друга через мобильный интернет.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _turnUrls,
            decoration: const InputDecoration(
              labelText: 'Адреса TURN (через запятую)',
              hintText: 'turn:global.relay.metered.ca:80',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _turnUser,
            decoration: const InputDecoration(labelText: 'Логин TURN', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _turnPass,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Пароль TURN', border: OutlineInputBorder()),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(widget.submitLabel),
          ),
        ],
      ),
    );
  }
}
