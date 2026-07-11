import 'package:flutter/material.dart';

class AppTheme {
  // Colors (Mapped to Spotify design guidelines)
  static const Color primaryDark = Color(0xFF090909);   // Background
  static const Color surfaceDark = Color(0xFF151515);   // Surface
  static const Color cardDark = Color(0xFF1D1D1D);      // Card
  static const Color accentPurple = Color(0xFF1ED760);   // Primary (Spotify Green)
  static const Color accentPink = Color(0xFF4A90E2);     // Secondary (Spotify Blue)
  static const Color accentBlue = Color(0xFF448AFF);     // Accent Blue
  static const Color textPrimary = Color(0xFFFFFFFF);    // White Text
  static const Color textSecondary = Color(0xFFB3B3B3);  // Subtitle/Gray Text
  static const Color textMuted = Color(0xFF6B6B6B);      // Muted Text
  static const Color divider = Color(0xFF2A2A2A);        // Divider
  static const Color error = Color(0xFFFF4D4F);          // Error Red

  // Aliases for modern naming
  static const Color background = primaryDark;
  static const Color surface = surfaceDark;
  static const Color card = cardDark;
  static const Color primary = accentPurple;
  static const Color secondary = accentPink;

  // Typography
  static const TextStyle display = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.bold,
    color: textPrimary,
  );

  static const TextStyle title = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.bold,
    color: textPrimary,
  );

  static const TextStyle heading = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    color: textPrimary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.normal,
    color: textSecondary,
  );

  static const TextStyle mini = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.normal,
    color: textMuted,
  );

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [accentPurple, Color(0xFF1DB954)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient backgroundGradient = LinearGradient(
    colors: [primaryDark, Color(0xFF121212)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static ThemeData get darkTheme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: primaryDark,
        primaryColor: accentPurple,
        colorScheme: const ColorScheme.dark(
          primary: accentPurple,
          secondary: accentPink,
          surface: surfaceDark,
        ),
        fontFamily: 'Outfit',
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: textPrimary,
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: accentPurple,
            foregroundColor: Colors.black87,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surfaceDark,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: textSecondary),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: primaryDark,
          selectedItemColor: accentPurple,
          unselectedItemColor: textMuted,
        ),
      );
}
