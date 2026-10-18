import 'package:flutter/material.dart';

/// HorseBox 主题：绿色主色，深色优先。
class HorseBoxTheme {
  static const seed = Color(0xFF4C8F6F);

  static ThemeData build({Brightness brightness = Brightness.dark}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF101613) : null,
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF18211C) : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF141C18) : scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        isDense: true,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.35),
        thickness: 1,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? const Color(0xFF141B17) : null,
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
      ),
    );
  }

  static TextStyle mono(BuildContext context, {double size = 13}) {
    return TextStyle(
      fontFamily: 'Consolas',
      fontSize: size,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}
