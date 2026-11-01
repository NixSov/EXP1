import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/rooms.dart';
import 'errors.dart';

/// Вход, регистрация и гостевой вход по коду комнаты.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    // Пришли по ссылке-приглашению — сразу открываем гостевой вход.
    final hasInvite = AppState.instance.pendingJoinCode.value != null;
    _tabs = TabController(length: 3, vsync: this, initialIndex: hasInvite ? 2 : 0);
    AppState.instance.pendingJoinCode.addListener(_onInvite);
  }

  void _onInvite() {
    if (AppState.instance.pendingJoinCode.value != null) _tabs.animateTo(2);
  }

  @override
  void dispose() {
    AppState.instance.pendingJoinCode.removeListener(_onInvite);
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shronshiki'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Вход'), Tab(text: 'Регистрация'), Tab(text: 'Гость')],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabs,
          children: const [_SignInForm(), _SignUpForm(), _GuestForm()],
        ),
      ),
    );
  }
}

class _FormShell extends StatelessWidget {
  const _FormShell({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

String? _validateEmail(String? v) {
  final text = (v ?? '').trim();
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text) ? null : 'Введите почту';
}

String? _validateName(String? v) {
  final text = (v ?? '').trim();
  if (text.isEmpty) return 'Введите имя';
  if (text.length > 40) return 'Не длиннее 40 символов';
  return null;
}

class _SignInForm extends StatefulWidget {
  const _SignInForm();

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<_SignInForm> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await AppState.instance.db.auth.signInWithPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: _FormShell(children: [
        TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Почта', border: OutlineInputBorder()),
          validator: _validateEmail,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _password,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          decoration: const InputDecoration(labelText: 'Пароль', border: OutlineInputBorder()),
          validator: (v) => (v ?? '').isEmpty ? 'Введите пароль' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy ? const _Spinner() : const Text('Войти'),
        ),
      ]),
    );
  }
}

class _SignUpForm extends StatefulWidget {
  const _SignUpForm();

  @override
  State<_SignUpForm> createState() => _SignUpFormState();
}

class _SignUpFormState extends State<_SignUpForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final res = await AppState.instance.db.auth.signUp(
        email: _email.text.trim(),
        password: _password.text,
        data: {'display_name': _name.text.trim()},
      );
      if (res.session == null && mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Подтвердите почту'),
            content: Text(
              'Мы отправили письмо на ${_email.text.trim()}. '
              'Перейдите по ссылке в письме, затем войдите на вкладке «Вход».',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Понятно')),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: _FormShell(children: [
        TextFormField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Имя', border: OutlineInputBorder()),
          validator: _validateName,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Почта', border: OutlineInputBorder()),
          validator: _validateEmail,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _password,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Пароль (не меньше 6 символов)',
            border: OutlineInputBorder(),
          ),
          validator: (v) => (v ?? '').length >= 6 ? null : 'Минимум 6 символов',
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy ? const _Spinner() : const Text('Зарегистрироваться'),
        ),
      ]),
    );
  }
}

class _GuestForm extends StatefulWidget {
  const _GuestForm();

  @override
  State<_GuestForm> createState() => _GuestFormState();
}

class _GuestFormState extends State<_GuestForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _code.text = AppState.instance.pendingJoinCode.value ?? '';
    AppState.instance.pendingJoinCode.addListener(_onInvite);
  }

  void _onInvite() {
    final code = AppState.instance.pendingJoinCode.value;
    if (code != null) _code.text = code;
  }

  @override
  void dispose() {
    AppState.instance.pendingJoinCode.removeListener(_onInvite);
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final code = RoomsRepository.normalizeCode(_code.text)!;
    setState(() => _busy = true);
    try {
      // После входа главный экран сам зайдёт в комнату с этим кодом.
      AppState.instance.pendingJoinCode.value = code;
      await AppState.instance.db.auth.signInAnonymously(
        data: {'display_name': _name.text.trim()},
      );
    } catch (e) {
      if (mounted) showError(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: _FormShell(children: [
        const Text('Войдите в комнату без регистрации — нужен только код от владельца комнаты.'),
        const SizedBox(height: 16),
        TextFormField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Ваше имя', border: OutlineInputBorder()),
          validator: _validateName,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _code,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Код комнаты или ссылка',
            hintText: 'ABC234',
            border: OutlineInputBorder(),
          ),
          validator: (v) =>
              RoomsRepository.normalizeCode(v ?? '') == null ? 'Код — 6 букв и цифр' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy ? const _Spinner() : const Text('Войти в комнату'),
        ),
      ]),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2));
}
