import 'package:flutter/material.dart';

/// HorseBox 主题：主色可自定义，深色优先。
class HorseBoxTheme {
  /// 默认主色（绿色）。
  static const seed = Color(0xFF4C8F6F);

  /// 可选主色，用户也可以自己调。
  static const presets = <Color>[
    Color(0xFF4C8F6F),
    Color(0xFF3B82F6),
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
    Color(0xFFEF4444),
    Color(0xFFF59E0B),
    Color(0xFF10B981),
    Color(0xFF06B6D4),
    Color(0xFF64748B),
    Color(0xFFD97706),
  ];

  static ThemeData build({
    Brightness brightness = Brightness.dark,
    int accent = 0xFF4C8F6F,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Color(accent),
      brightness: brightness,
    );
    final dark = brightness == Brightness.dark;
    // 深色背景保持中性，只带一点主色的味道，换主色时不会整屏变色。
    final background = dark
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.035),
            const Color(0xFF0F1011),
          )
        : null;
    final cardColor = dark
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.06),
            const Color(0xFF16181A),
          )
        : scheme.surfaceContainerLow;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardTheme: CardThemeData(
        elevation: 0,
        color: cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.05),
                const Color(0xFF14161A),
              )
            : scheme.surfaceContainerHighest,
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
        backgroundColor: dark
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.05),
                const Color(0xFF14161A),
              )
            : null,
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
