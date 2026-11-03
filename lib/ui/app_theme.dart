import 'package:flutter/material.dart';

/// 工业工作台的统一视觉令牌：灰阶承载结构，仅蓝色表示选择和主要操作。
/// 不同亮度共用布局、间距和细边框，避免主题切换后出现颜色或层级失配。
ThemeData buildIndustrialTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final surface = dark ? const Color(0xFF22262B) : const Color(0xFFFFFFFF);
  final background = dark ? const Color(0xFF191D22) : const Color(0xFFF2F3F5);
  final container = dark ? const Color(0xFF2A2F35) : const Color(0xFFECEFF2);
  final border = dark ? const Color(0xFF414851) : const Color(0xFFCED4DB);
  final text = dark ? const Color(0xFFE0E4E9) : const Color(0xFF222B35);
  // 次要文字仍须在浅灰背景达到普通文本的 4.5:1 对比度。
  final secondary = dark ? const Color(0xFFA5AFBB) : const Color(0xFF626D7A);
  final accent = dark ? const Color(0xFF79AAED) : const Color(0xFF245FA8);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary: dark ? const Color(0xFF112843) : Colors.white,
        surface: surface,
        surfaceContainer: container,
        surfaceContainerLow: background,
        surfaceContainerHigh: container,
        onSurface: text,
        onSurfaceVariant: secondary,
        outline: border,
        outlineVariant: border,
        surfaceTint: Colors.transparent,
      );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(4));
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Microsoft YaHei UI',
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    dividerColor: border,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    textTheme: TextTheme(
      bodyLarge: TextStyle(fontSize: 13, color: text),
      bodyMedium: TextStyle(fontSize: 12, color: text),
      bodySmall: TextStyle(fontSize: 11, color: secondary),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      titleMedium: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: text,
      ),
      labelLarge: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: accent),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        minimumSize: const Size(0, 34),
        foregroundColor: text,
        side: BorderSide(color: border),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: shape,
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: shape,
        iconSize: 17,
        minimumSize: const Size(30, 30),
        padding: const EdgeInsets.all(5),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      side: BorderSide(color: secondary),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
    ),
  );
}
