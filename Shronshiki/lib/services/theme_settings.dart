import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode { light, dark, custom }

/// Тема оформления: светлая, тёмная или своя (цвет/картинка фона, цвет текста,
/// вторичный цвет для кнопок и акцентов). Хранится на устройстве.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings._(this._prefs);

  static const _kMode = 'theme_mode';
  static const _kBackground = 'theme_bg_color';
  static const _kText = 'theme_text_color';
  static const _kAccent = 'theme_accent_color';
  static const _kImage = 'theme_bg_image';
  static const _kDim = 'theme_bg_dim';

  static const defaultSeed = Color(0xFF5865F2);
  static const defaultBackground = Color(0xFF1E1F22);
  static const defaultText = Color(0xFFF2F3F5);

  final SharedPreferences _prefs;

  static Future<ThemeSettings> load() async =>
      ThemeSettings._(await SharedPreferences.getInstance());

  AppThemeMode get mode =>
      AppThemeMode.values.asNameMap()[_prefs.getString(_kMode)] ?? AppThemeMode.dark;
  set mode(AppThemeMode value) => _save(() => _prefs.setString(_kMode, value.name));

  Color get background => Color(_prefs.getInt(_kBackground) ?? defaultBackground.toARGB32());
  set background(Color value) => _save(() => _prefs.setInt(_kBackground, value.toARGB32()));

  Color get text => Color(_prefs.getInt(_kText) ?? defaultText.toARGB32());
  set text(Color value) => _save(() => _prefs.setInt(_kText, value.toARGB32()));

  Color get accent => Color(_prefs.getInt(_kAccent) ?? defaultSeed.toARGB32());
  set accent(Color value) => _save(() => _prefs.setInt(_kAccent, value.toARGB32()));

  /// Затемнение картинки фона (0 — нет, 0.8 — почти чёрная), чтобы текст читался.
  double get imageDim => _prefs.getDouble(_kDim) ?? 0.4;
  set imageDim(double value) => _save(() => _prefs.setDouble(_kDim, value));

  /// Картинка фона (копия в папке приложения). null — фон цветом.
  String? get imagePath {
    // В браузере файлов нет — только цвет.
    if (kIsWeb) return null;
    final path = _prefs.getString(_kImage);
    return path != null && File(path).existsSync() ? path : null;
  }

  bool get hasImage => mode == AppThemeMode.custom && imagePath != null;

  void _save(Future<bool> Function() write) {
    write();
    notifyListeners();
  }

  /// Выбор картинки из галереи. Возвращает false, если пользователь передумал.
  Future<bool> pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 90,
    );
    if (picked == null) return false;
    final dir = await getApplicationDocumentsDirectory();
    final ext = picked.path.contains('.') ? picked.path.split('.').last : 'jpg';
    final target = File('${dir.path}/theme_background_${DateTime.now().millisecondsSinceEpoch}.$ext');
    await File(picked.path).copy(target.path);
    final old = _prefs.getString(_kImage);
    await _prefs.setString(_kImage, target.path);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    notifyListeners();
    return true;
  }

  Future<void> removeImage() async {
    final old = _prefs.getString(_kImage);
    await _prefs.remove(_kImage);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> resetCustom() async {
    await removeImage();
    for (final key in [_kBackground, _kText, _kAccent, _kDim]) {
      await _prefs.remove(key);
    }
    notifyListeners();
  }

  ThemeData get themeData => switch (mode) {
        AppThemeMode.light => ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: defaultSeed),
            useMaterial3: true,
          ),
        AppThemeMode.dark => ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: defaultSeed, brightness: Brightness.dark),
            useMaterial3: true,
          ),
        AppThemeMode.custom => _customTheme(),
      };

  static Color _contrastOn(Color c) =>
      c.computeLuminance() > 0.45 ? Colors.black : Colors.white;

  ThemeData _customTheme() {
    final bg = background;
    final fg = text;
    final accentColor = accent;
    // Светлый текст — значит, основа тёмная, и наоборот.
    final dark = fg.computeLuminance() > 0.45;
    final withImage = hasImage;

    // Панели (карточки, диалоги) — цвет фона с небольшой примесью цвета текста.
    Color panel(double mix, {int alpha = 255}) =>
        Color.lerp(bg, fg, mix)!.withAlpha(alpha);
    final cardAlpha = withImage ? 190 : 255;

    final base = ColorScheme.fromSeed(
      seedColor: accentColor,
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    final scheme = base.copyWith(
      primary: accentColor,
      onPrimary: _contrastOn(accentColor),
      secondary: accentColor,
      onSecondary: _contrastOn(accentColor),
      primaryContainer: Color.lerp(bg, accentColor, 0.4),
      onPrimaryContainer: fg,
      secondaryContainer: Color.lerp(bg, accentColor, 0.3),
      onSecondaryContainer: fg,
      surface: withImage ? Colors.transparent : bg,
      onSurface: fg,
      onSurfaceVariant: fg.withValues(alpha: 0.75),
      surfaceContainerLowest: panel(0.02, alpha: cardAlpha),
      surfaceContainerLow: panel(0.05, alpha: cardAlpha),
      surfaceContainer: panel(0.08, alpha: cardAlpha),
      surfaceContainerHigh: panel(0.11, alpha: cardAlpha),
      surfaceContainerHighest: panel(0.15, alpha: cardAlpha),
      outline: fg.withValues(alpha: 0.45),
      outlineVariant: fg.withValues(alpha: 0.2),
    );
    final opaquePanel = panel(0.08);
    final textTheme = (dark ? Typography.material2021().white : Typography.material2021().black)
        .apply(bodyColor: fg, displayColor: fg);

    return ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      textTheme: textTheme,
      iconTheme: IconThemeData(color: fg),
      scaffoldBackgroundColor: withImage ? Colors.transparent : bg,
      canvasColor: withImage ? opaquePanel : bg,
      appBarTheme: AppBarTheme(
        backgroundColor: withImage ? Colors.transparent : bg,
        foregroundColor: fg,
        surfaceTintColor: Colors.transparent,
      ),
      // Всплывающие окна всегда непрозрачные, чтобы читались поверх картинки.
      dialogTheme: DialogThemeData(backgroundColor: panel(0.11)),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: opaquePanel,
        modalBackgroundColor: opaquePanel,
      ),
      popupMenuTheme: PopupMenuThemeData(color: panel(0.11)),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: fg,
        contentTextStyle: TextStyle(color: bg),
      ),
    );
  }

  /// Подложка всего приложения: картинка с затемнением (только своя тема).
  Widget wrapBackground(Widget child) {
    final path = imagePath;
    if (mode != AppThemeMode.custom || path == null) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(File(path), fit: BoxFit.cover, gaplessPlayback: true),
        ColoredBox(color: Colors.black.withValues(alpha: imageDim)),
        child,
      ],
    );
  }
}
