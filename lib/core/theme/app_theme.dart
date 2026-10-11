/// One visual identity for the whole app: colours, type, shapes, and the
/// component themes every screen inherits.
///
/// Screens should read these through `Theme.of(context)` rather than naming
/// colours themselves — that is what makes a palette change a one-file edit,
/// and what stops five shades of "grey card" from accumulating across
/// eleven screens.
library;

import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

/// Semantic colours that are *not* derivable from the seed (success/warning
/// states, the two chat bubble roles, the glow behind AI content).
class AppColors {
  AppColors._();

  /// The brand indigo the app has used since v1.0 — kept so existing installs
  /// still look like the same product.
  static const Color brand = AppConstants.primaryColor;

  /// Secondary accent for AI-authored surfaces and progress: a cool cyan that
  /// reads as "machine" against the indigo without competing with it.
  static const Color accent = Color(0xFF22D3EE);

  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);

  /// Page background — darker than the cards so elevation reads even at 0dp.
  static const Color background = Color(0xFF0B0C11);

  /// Card / sheet surface.
  static const Color surface = Color(0xFF14161D);

  /// Raised surface (dialogs, expanded cards, the input bar).
  static const Color surfaceHigh = Color(0xFF1C1F28);

  /// The model's own bubble; the user's is the brand indigo.
  static const Color aiBubble = Color(0xFF1B1E27);
  static const Color userBubble = Color(0xFF4F46E5);
}

class AppTheme {
  AppTheme._();

  static const Color _seed = AppConstants.primaryColor;

  /// Corner radius used everywhere. 16 for containers, 12 for controls —
  /// large enough to feel soft, small enough not to look like a toy.
  static const double radiusLarge = 16;
  static const double radiusMedium = 12;
  static const double radiusSmall = 8;

  /// The dark theme.
  ///
  /// Dark is not a preference here: the app is a long-session chat client and
  /// a model download progress screen, both of which people run at night. The
  /// surfaces are stepped (`background < surface < surfaceHigh`) instead of
  /// relying on elevation shadows, because shadows on near-black are invisible
  /// and elevation then carries no information.
  static ThemeData get dark {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ).copyWith(
          primary: _seed,
          secondary: AppColors.accent,
          surface: AppColors.surface,
          surfaceContainerLowest: AppColors.background,
          surfaceContainerLow: Color(0xFF10121A),
          surfaceContainer: AppColors.surface,
          surfaceContainerHigh: AppColors.surfaceHigh,
          surfaceContainerHighest: Color(0xFF242833),
          error: AppColors.danger,
          outline: const Color(0xFF2E3341),
        );

    final text = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      textTheme: text,

      // ------------------------------------------------------------- chrome
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: AppColors.background,
        foregroundColor: scheme.onSurface,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
        height: 68,
        elevation: 0,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelMedium?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.22),
      ),

      // --------------------------------------------------------- containers
      cardTheme: CardThemeData(
        elevation: 0,
        color: AppColors.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge + 4),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        elevation: 0,
        backgroundColor: AppColors.surfaceHigh,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.surfaceHigh,
        contentTextStyle: text.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
      ),

      // ----------------------------------------------------------- controls
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(64, 48),
          elevation: 0,
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusMedium),
            ),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),

      // ------------------------------------------------------------ inputs
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceHigh,
        hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
          borderSide: BorderSide(color: scheme.error),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
        ),
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        thumbColor: scheme.primary,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.onSurfaceVariant,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: AppColors.surfaceHigh,
        circularTrackColor: AppColors.surfaceHigh,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: AppColors.surfaceHigh,
        selectedColor: scheme.primary.withValues(alpha: 0.22),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
        ),
        labelStyle: text.labelMedium,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        radius: const Radius.circular(8),
        thickness: WidgetStatePropertyAll(6),
      ),
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      // Every route in the app is pushed with MaterialPageRoute, so this is
      // where the transition is decided: a short fade-up instead of the
      // platform's full-width slide. Pushes here are shallow (settings, model
      // picker, dialogs) and a slide implies a depth hierarchy that does not
      // exist.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          // Android only: the app locks to portrait and targets Android, and
          // CupertinoPageTransitionsBuilder is not in material's export
          // (it lives in cupertino.dart) — naming it here does not compile.
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// The type scale.
  ///
  /// Slightly tighter than the Material defaults (line height 1.3 instead of
  /// 1.4 for body) because chat is a line-oriented format: looser leading
  /// makes a transcript feel like a slide deck. Sizes are otherwise stock so
  /// the system font-scaling slider keeps behaving the way users expect.
  static TextTheme _textTheme(ColorScheme scheme) {
    const color = Color(0xFFE9ECF5);
    const muted = Color(0xFF9AA3B5);

    return TextTheme(
      displaySmall: const TextStyle(
        fontSize: 34,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: color,
      ),
      headlineSmall: const TextStyle(
        fontSize: 24,
        height: 1.25,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: color,
      ),
      titleLarge: TextStyle(
        fontSize: 19,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: scheme.onSurface,
      ),
      titleMedium: const TextStyle(
        fontSize: 16,
        height: 1.35,
        fontWeight: FontWeight.w600,
        color: color,
      ),
      bodyLarge: const TextStyle(fontSize: 16, height: 1.45, color: color),
      bodyMedium: const TextStyle(fontSize: 14.5, height: 1.45, color: color),
      bodySmall: const TextStyle(fontSize: 12.5, height: 1.4, color: muted),
      labelLarge: const TextStyle(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        color: color,
      ),
      labelMedium: const TextStyle(
        fontSize: 12.5,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
      labelSmall: const TextStyle(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: muted,
      ),
    );
  }
}
