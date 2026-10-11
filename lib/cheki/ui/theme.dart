import 'package:flutter/material.dart';

abstract final class ChekiColors {
  static const background = Color(0xFFF7F9FC);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF263B50);
  static const muted = Color(0xFF5F6F80);
  static const line = Color(0xFFE1E7EF);
  static const inputBorder = Color(0xFF7C8EA0);
  static const blue = Color(0xFFDCEFFA);
  static const blueInk = Color(0xFF365F79);
  static const pink = Color(0xFFF9E3EB);
  static const pinkInk = Color(0xFF81485F);
  static const warning = Color(0xFF885B16);
  static const warningSurface = Color(0xFFFFF1D7);
  static const danger = Color(0xFFA73748);
  static const dangerSurface = Color(0xFFFDE9EC);
  static const success = Color(0xFF28634D);
  static const successSurface = Color(0xFFE4F2EB);
}

ThemeData chekiTheme() {
  const outline = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    borderSide: BorderSide(color: ChekiColors.inputBorder),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: ChekiColors.background,
    colorScheme: const ColorScheme.light(
      primary: ChekiColors.blueInk,
      onPrimary: ChekiColors.surface,
      primaryContainer: ChekiColors.blue,
      onPrimaryContainer: ChekiColors.blueInk,
      secondary: ChekiColors.pinkInk,
      onSecondary: ChekiColors.surface,
      secondaryContainer: ChekiColors.pink,
      onSecondaryContainer: ChekiColors.pinkInk,
      surface: ChekiColors.surface,
      onSurface: ChekiColors.ink,
      onSurfaceVariant: ChekiColors.muted,
      outline: ChekiColors.inputBorder,
      outlineVariant: ChekiColors.line,
      error: ChekiColors.danger,
      onError: ChekiColors.surface,
      errorContainer: ChekiColors.dangerSurface,
      onErrorContainer: ChekiColors.danger,
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 40,
        fontWeight: FontWeight.w600,
        color: ChekiColors.ink,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: ChekiColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: ChekiColors.ink,
      ),
      bodyLarge: TextStyle(fontSize: 15, height: 1.5, color: ChekiColors.ink),
      bodyMedium: TextStyle(fontSize: 15, height: 1.5, color: ChekiColors.ink),
      bodySmall: TextStyle(fontSize: 13, height: 1.5, color: ChekiColors.muted),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ChekiColors.background,
      foregroundColor: ChekiColors.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: ChekiColors.ink,
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: ChekiColors.surface,
      border: outline,
      enabledBorder: outline,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: ChekiColors.blueInk, width: 2),
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ChekiColors.blue,
        foregroundColor: ChekiColors.blueInk,
        minimumSize: const Size(44, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: ChekiColors.ink,
        minimumSize: const Size(44, 44),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: ChekiColors.surface,
      indicatorColor: ChekiColors.blue,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    dividerColor: ChekiColors.line,
  );
}
