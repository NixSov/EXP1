import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'screens/setup_screen.dart';
import 'services/background_call.dart';
import 'services/call_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundCall.init();
  CallSession.init();
  await AppState.init();
  runApp(const ShronshikiApp());
}

class ShronshikiApp extends StatelessWidget {
  const ShronshikiApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5865F2);
    return MaterialApp(
      title: 'Shronshiki',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const RootScreen(),
    );
  }
}

/// Выбирает экран: настройка сервера → вход → главная.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    if (!app.supabaseReady) {
      return SetupScreen(onDone: () => setState(() {}));
    }
    return StreamBuilder<AuthState>(
      stream: app.db.auth.onAuthStateChange,
      builder: (context, _) {
        final user = app.db.auth.currentUser;
        if (user == null) return const AuthScreen();
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // Во время звонка «Назад» сворачивает приложение, а не завершает звонок.
            if (CallSession.current.value?.isActive ?? false) {
              BackgroundCall.moveToBack();
            } else {
              SystemNavigator.pop();
            }
          },
          child: HomeScreen(key: ValueKey(user.id)),
        );
      },
    );
  }
}
