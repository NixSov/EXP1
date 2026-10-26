import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Понятное сообщение об ошибке на русском.
String describeError(Object error) {
  if (error is AuthException) {
    final msg = error.message.toLowerCase();
    if (msg.contains('invalid login credentials')) return 'Неверная почта или пароль';
    if (msg.contains('email not confirmed')) return 'Почта не подтверждена — проверьте письмо';
    if (msg.contains('already registered')) return 'Эта почта уже зарегистрирована';
    if (msg.contains('anonymous sign-ins are disabled')) {
      return 'Гостевой вход выключен в настройках Supabase (Authentication → Sign In / Providers → Anonymous)';
    }
    if (msg.contains('rate limit')) return 'Слишком много попыток, попробуйте позже';
    if (msg.contains('password')) return 'Пароль не подходит: ${error.message}';
    return 'Ошибка входа: ${error.message}';
  }
  if (error is PostgrestException) {
    if (error.code == '42883' || error.code == 'PGRST202') {
      return 'База данных не настроена: выполните SQL-миграцию из папки supabase/migrations';
    }
    if (error.code == '42501') return 'Недостаточно прав для этого действия';
    return 'Ошибка сервера: ${error.message}';
  }
  if (error is SocketException || error is TimeoutException || error is HttpException) {
    return 'Нет связи с сервером. Проверьте интернет.';
  }
  final text = error.toString();
  if (text.contains('SocketException') || text.contains('Failed host lookup')) {
    return 'Нет связи с сервером. Проверьте интернет.';
  }
  return text;
}

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
