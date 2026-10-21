import 'package:flutter/material.dart';

/// Brand kit v1.0. Lime is for actions and progress only — never body text.
class Brand {
  const Brand._();

  static const ink = Color(0xFF0B0E13);
  static const lime = Color(0xFFC6F232);
  static const mint = Color(0xFF7DE3A7);
  static const slate = Color(0xFF8A93A3);
  static const card = Color(0xFF141922);
  static const card2 = Color(0xFF1B212B);
  static const chip = Color(0xFF232B38);
  static const track = Color(0xFF2A323F);
  static const border = Color(0xFF3A4353);
  static const text = Color(0xFFEEF2F5);
  static const textDim = Color(0xFFAAB3C2);
  static const danger = Color(0xFFFF7A7A);

  static const radius = 16.0;
  static const progressGradient = LinearGradient(colors: [lime, mint]);
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    surface: Brand.ink,
    primary: Brand.lime,
    onPrimary: Brand.ink,
    secondary: Brand.mint,
    onSecondary: Brand.ink,
    error: Brand.danger,
    onSurface: Brand.text,
    surfaceContainerHighest: Brand.card2,
    surfaceContainerHigh: Brand.card2,
    surfaceContainer: Brand.card,
    outline: Brand.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Brand.ink,
    // System font stack (SF on iOS, Roboto on Android): zero font cost.
  );
  final text = base.textTheme.apply(
    bodyColor: Brand.text,
    displayColor: Brand.text,
  );
  return base.copyWith(
    textTheme: text.copyWith(
      headlineLarge: text.headlineLarge?.copyWith(
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        height: 1.1,
      ),
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      bodySmall: text.bodySmall?.copyWith(color: Brand.slate),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Brand.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: Brand.card2,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Brand.radius),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.lime,
        foregroundColor: Brand.ink,
        disabledBackgroundColor: Brand.track,
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Brand.text,
        side: const BorderSide(color: Brand.border),
        minimumSize: const Size.fromHeight(46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Brand.textDim),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Brand.chip,
      selectedColor: Brand.lime,
      labelStyle: const TextStyle(color: Brand.text),
      secondaryLabelStyle: const TextStyle(
        color: Brand.ink,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Brand.card,
      indicatorColor: Brand.lime.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? Brand.lime : Brand.slate,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 12,
          color: s.contains(WidgetState.selected) ? Brand.text : Brand.slate,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.card2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      hintStyle: const TextStyle(color: Brand.slate),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Brand.card,
      showDragHandle: true,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Brand.card2,
      contentTextStyle: TextStyle(color: Brand.text),
      behavior: SnackBarBehavior.floating,
    ),
    dividerTheme: const DividerThemeData(color: Brand.track),
  );
}
