import 'package:flutter/material.dart';

class NetcattyTheme {
  static const accent = Color(0xfff97316);
  static const background = Color(0xff0d0f12);
  static const surface = Color(0xff15181d);
  static const border = Color(0xff292d34);

  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: background,
    colorScheme: const ColorScheme.dark(
      primary: accent,
      secondary: Color(0xffffa45b),
      surface: surface,
      outline: border,
      error: Color(0xffef4444),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Color(0xff111318),
      indicatorColor: Color(0x33f97316),
      height: 68,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xff111318),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
    ),
  );

  static ThemeData get light => ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: accent),
  );
}
