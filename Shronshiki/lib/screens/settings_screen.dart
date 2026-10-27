import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_state.dart';
import '../services/background_call.dart';
import '../services/call_session.dart';
import '../services/diagnostics.dart';
import '../services/ice_check.dart';
import '../services/platform_check.dart';
import '../services/server_route.dart';
import '../services/theme_settings.dart';
import '../widgets/color_picker_dialog.dart';
import 'errors.dart';
import 'setup_screen.dart';
import '../services/updater.dart';
import '../widgets/app_update.dart';

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

  Future<void> _runDiagnostics() => _runCheck('Проверка связи', Diagnostics.run);

  Future<void> _runIceCheck() => _runCheck('Прямое соединение', IceCheck.run);

  Future<void> _runPlatformCheck() => _runCheck('Проверка площадок', PlatformCheck.run);

  Future<void> _runCheck(
    String title,
    Future<List<DiagResult>> Function(void Function(List<DiagResult>) onProgress) runner,
  ) async {
    final results = ValueNotifier<List<DiagResult>>([]);
    final done = ValueNotifier(false);
    runner((r) => results.value = r).whenComplete(() => done.value = true);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ListenableBuilder(
          listenable: Listenable.merge([results, done]),
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final r in results.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('${r.ok ? '✅' : '❌'} ${r.title}\n${r.detail}'),
                ),
              if (!done.value) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          ListenableBuilder(
            listenable: done,
            builder: (context, _) => TextButton(
              onPressed: done.value
                  ? () {
                      Clipboard.setData(ClipboardData(text: results.value.join('\n')));
                      showError(this.context, 'Результат скопирован');
                    }
                  : null,
              child: const Text('Скопировать'),
            ),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  List<Widget> _routeSection(BuildContext context) {
    final route = _app.route;
    if (!route.hasProxy) {
      return const [
        ListTile(
          leading: Icon(Icons.alt_route),
          title: Text('Подключение к серверу: напрямую'),
          subtitle: Text('Посредник не настроен (Supabase и TURN → «Посредник»)'),
        ),
      ];
    }
    return [
      ListTile(
        leading: const Icon(Icons.alt_route),
        title: const Text('Подключение к серверу'),
        subtitle: Text('Сейчас: ${route.description}'),
        trailing: IconButton(
          tooltip: 'Перемерить',
          icon: const Icon(Icons.refresh),
          onPressed: () => route.probe(force: true),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SegmentedButton<RouteMode>(
          segments: const [
            ButtonSegment(value: RouteMode.auto, label: Text('Авто')),
            ButtonSegment(value: RouteMode.direct, label: Text('Напрямую')),
            ButtonSegment(value: RouteMode.proxy, label: Text('Посредник')),
          ],
          selected: {route.mode},
          onSelectionChanged: (v) => route.mode = v.first,
        ),
      ),
    ];
  }

  List<Widget> _themeSection(BuildContext context) {
    final theme = _app.theme;
    final custom = theme.mode == AppThemeMode.custom;
    Widget swatch(Color c) => Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.grey.withValues(alpha: 0.6)),
          ),
        );
    return [
      const _Header('Оформление'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: SegmentedButton<AppThemeMode>(
          segments: const [
            ButtonSegment(value: AppThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Светлая')),
            ButtonSegment(value: AppThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Тёмная')),
            ButtonSegment(value: AppThemeMode.custom, icon: Icon(Icons.palette), label: Text('Своя')),
          ],
          selected: {theme.mode},
          onSelectionChanged: (v) => theme.mode = v.first,
        ),
      ),
      if (custom) ...[
        ListTile(
          leading: const Icon(Icons.wallpaper),
          title: const Text('Фон'),
          subtitle: Text(theme.imagePath != null ? 'Картинка' : 'Цвет'),
          trailing: theme.imagePath != null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(File(theme.imagePath!), width: 40, height: 40, fit: BoxFit.cover),
                )
              : swatch(theme.background),
          onTap: _chooseBackground,
        ),
        if (theme.imagePath != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('Затемнение'),
                Expanded(
                  child: Slider(
                    value: theme.imageDim,
                    max: 0.8,
                    divisions: 16,
                    label: '${(theme.imageDim * 100).round()}%',
                    onChanged: (v) => theme.imageDim = v,
                  ),
                ),
              ],
            ),
          ),
        ListTile(
          leading: const Icon(Icons.text_fields),
          title: const Text('Цвет текста'),
          trailing: swatch(theme.text),
          onTap: () => _pickColor('Цвет текста', theme.text, (c) => theme.text = c),
        ),
        ListTile(
          leading: const Icon(Icons.color_lens_outlined),
          title: const Text('Вторичный цвет'),
          subtitle: const Text('Кнопки, переключатели, выделение'),
          trailing: swatch(theme.accent),
          onTap: () => _pickColor('Вторичный цвет', theme.accent, (c) => theme.accent = c),
        ),
        ListTile(
          leading: const Icon(Icons.restart_alt),
          title: const Text('Сбросить свою тему'),
          onTap: theme.resetCustom,
        ),
      ],
    ];
  }

  Future<void> _pickColor(String title, Color initial, ValueChanged<Color> apply) async {
    final color = await showColorPickerDialog(context, title: title, initial: initial);
    if (color != null) apply(color);
  }

  Future<void> _chooseBackground() async {
    final theme = _app.theme;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.format_color_fill),
              title: const Text('Цвет фона'),
              subtitle: theme.imagePath != null
                  ? const Text('Картинка будет убрана; цвет останется у панелей')
                  : null,
              onTap: () => Navigator.pop(context, 'color'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Картинка из галереи'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            if (theme.imagePath != null)
              ListTile(
                leading: const Icon(Icons.hide_image_outlined),
                title: const Text('Убрать картинку'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'color':
        final color = await showColorPickerDialog(context, title: 'Цвет фона', initial: theme.background);
        if (color != null) {
          theme.background = color;
          await theme.removeImage();
        }
      case 'image':
        try {
          await theme.pickImage();
        } catch (e) {
          if (mounted) showError(context, 'Не удалось открыть картинку: $e');
        }
      case 'remove':
        await theme.removeImage();
    }
  }

  Future<void> _testHeadsetButton() async {
    final presses = ValueNotifier<List<String>>([]);
    await BackgroundCall.startButtonTest((key) => presses.value = [...presses.value, key]);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Кнопка наушников'),
        content: ValueListenableBuilder<List<String>>(
          valueListenable: presses,
          builder: (context, list, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(BackgroundCall.supported
                  ? 'Подключите наушники и один раз нажмите кнопку, которой ставите музыку на паузу.'
                  : 'Нажмите клавишу Play/Pause на клавиатуре или кнопку на наушниках.'),
              const SizedBox(height: 16),
              if (list.isEmpty)
                const Row(
                  children: [
                    SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 12),
                    Text('Ждём нажатия…'),
                  ],
                )
              else ...[
                Text('✅ Нажатие получено (${list.length})',
                    style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('Сигнал: ${list.last}', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                const Text('Во время звонка это нажатие будет включать и выключать микрофон.'),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
        ],
      ),
    );
    await BackgroundCall.stopButtonTest();
  }

  Future<void> _signOut() async {
    final navigator = Navigator.of(context);
    await CallSession.leave();
    navigator.popUntil((route) => route.isFirst);
    await _app.db.auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final user = _app.db.auth.currentUser;
    final settings = _app.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: ListenableBuilder(
        listenable: Listenable.merge([settings, _app.theme, _app.route]),
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
            ..._themeSection(context),
            const Divider(),
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
                onTap: BackgroundCall.requestIgnoreBatteryOptimizations,
              ),
            if (BackgroundCall.hasHeadsetButton)
              ListTile(
                leading: const Icon(Icons.headset_mic_outlined),
                title: const Text('Проверка кнопки наушников'),
                subtitle: Text(BackgroundCall.supported
                    ? 'Во время звонка одно нажатие на наушниках включает и выключает микрофон'
                    : 'Во время звонка клавиша Play/Pause (или кнопка на наушниках) '
                        'включает и выключает микрофон'),
                onTap: _testHeadsetButton,
              ),
            const Divider(),
            const _Header('Сервер'),
            ..._routeSection(context),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: const Text('Проверить связь с сервером'),
              subtitle: const Text('Покажет, мешает ли провайдер (сравните с VPN и без)'),
              onTap: _runDiagnostics,
            ),
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Проверить прямое соединение'),
              subtitle: const Text('STUN и TURN: смогут ли телефоны найти друг друга'),
              onTap: _runIceCheck,
            ),
            ListTile(
              leading: const Icon(Icons.travel_explore),
              title: const Text('Проверить площадки'),
              subtitle: const Text('Google Firebase, Deno Deploy, Netlify — доступны ли без VPN'),
              onTap: _runPlatformCheck,
            ),
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
            if (Updater.supported) ...[
              const Divider(),
              const _Header('Обновления'),
              const UpdateTile(),
            ],
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
