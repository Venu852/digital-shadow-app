import 'package:flutter/material.dart';
import 'package:test_app/drift/drift_engine.dart';

/// The app's palette. Status colours are always shown next to their label.
class ShadowColors {
  static const Color background = Color(0xFF020617);
  static const Color card = Color(0xFF0F172A);
  static const Color border = Color(0xFF1E293B);
  static const Color text = Color(0xFFF1F5F9);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color primary = Color(0xFF818CF8);
  static const Color onPrimary = Color(0xFF020617);
  static const Color selected = Color(0xFF1E1B4B);
  static const Color selectedBorder = Color(0xFF6366F1);

  /// "Above your usual" and over-limit.
  static const Color amber = Color(0xFFF59E0B);
  static const Color amberText = Color(0xFFFBBF24);

  static const Map<DriftBand, Color> bands = {
    DriftBand.stable: Color(0xFF6366F1),
    DriftBand.early: Color(0xFF818CF8),
    DriftBand.elevated: Color(0xFFF59E0B),
    DriftBand.high: Color(0xFFFB923C),
  };
}

const double minTouchTarget = 44;

ThemeData buildShadowTheme() {
  const scheme = ColorScheme.dark(
    primary: ShadowColors.primary,
    onPrimary: ShadowColors.onPrimary,
    primaryContainer: ShadowColors.selected,
    onPrimaryContainer: ShadowColors.text,
    secondary: ShadowColors.selectedBorder,
    onSecondary: ShadowColors.text,
    secondaryContainer: ShadowColors.selected,
    onSecondaryContainer: ShadowColors.text,
    surface: ShadowColors.card,
    onSurface: ShadowColors.text,
    onSurfaceVariant: ShadowColors.textSecondary,
    surfaceContainerHighest: ShadowColors.border,
    outline: ShadowColors.textSecondary,
    outlineVariant: ShadowColors.border,
    // No red alarms: errors use the high-drift orange.
    error: Color(0xFFFB923C),
    onError: ShadowColors.onPrimary,
  );
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
    side: BorderSide(color: ShadowColors.border),
  );
  const buttonSize = Size(minTouchTarget, minTouchTarget);
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
  );
  return base.copyWith(
    scaffoldBackgroundColor: ShadowColors.background,
    canvasColor: ShadowColors.background,
    dividerColor: ShadowColors.border,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: base.textTheme.apply(
      bodyColor: ShadowColors.text,
      displayColor: ShadowColors.text,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ShadowColors.background,
      foregroundColor: ShadowColors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: const CardThemeData(
      color: ShadowColors.card,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: shape,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: ShadowColors.card,
      surfaceTintColor: Colors.transparent,
      shape: shape,
    ),
    dividerTheme: const DividerThemeData(color: ShadowColors.border),
    listTileTheme: const ListTileThemeData(
      iconColor: ShadowColors.textSecondary,
      minTileHeight: minTouchTarget,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ShadowColors.card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: ShadowColors.selected,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            color: states.contains(WidgetState.selected)
                ? ShadowColors.text
                : ShadowColors.textSecondary,
          )),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? ShadowColors.primary
                : ShadowColors.textSecondary,
          )),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ShadowColors.primary,
        foregroundColor: ShadowColors.onPrimary,
        minimumSize: buttonSize,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: ShadowColors.primary,
        foregroundColor: ShadowColors.onPrimary,
        minimumSize: buttonSize,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ShadowColors.text,
        side: const BorderSide(color: ShadowColors.border),
        minimumSize: buttonSize,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ShadowColors.primary,
        minimumSize: buttonSize,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: ShadowColors.card,
      selectedColor: ShadowColors.selected,
      labelStyle: const TextStyle(color: ShadowColors.text),
      side: WidgetStateBorderSide.resolveWith((states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? ShadowColors.selectedBorder
                : ShadowColors.border,
          )),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12))),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ShadowColors.primary,
      linearTrackColor: ShadowColors.border,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: ShadowColors.border,
      contentTextStyle: TextStyle(color: ShadowColors.text),
    ),
  );
}
