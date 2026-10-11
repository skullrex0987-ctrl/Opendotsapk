/// Smoke tests for the theme: the values every screen reads through
/// `Theme.of(context)`.
///
/// These are plain `expect` calls on the returned [ThemeData]. Nothing is
/// pumped, no plugin is touched, and no platform channel is invoked, because
/// this file has to be one of the cheapest and most reliable tests in the
/// suite — a theme regression shows up as eleven screens drifting apart, and
/// the cheapest guard is to pin the handful of values they all depend on.
///
/// What is asserted is deliberately the *contract*, not a rendering: that the
/// dark theme really is dark, that the scaffold sits on the app's own
/// background colour, and that every hand-picked colour in [AppColors] is
/// fully opaque. A translucent brand colour would render as an unpredictable
/// blend over whatever is behind it and is exactly the kind of thing that
/// looks fine on one surface and wrong on another.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/theme/app_theme.dart';

void main() {
  group('AppTheme.dark', () {
    test('is a dark Material 3 theme', () {
      final theme = AppTheme.dark;

      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.brightness, Brightness.dark);
      // ThemeData derives its own `brightness` from the colour scheme; if these
      // ever disagree, a screen reading one and a widget resolving the other
      // pick different text colours.
      expect(theme.brightness, Brightness.dark);
    });

    test(
      'puts the scaffold on the app background, not on the card surface',
      () {
        final theme = AppTheme.dark;

        expect(theme.scaffoldBackgroundColor, AppColors.background);
        // Cards must be a *different*, lighter step or elevation carries no
        // information at all on a near-black page.
        expect(theme.colorScheme.surface, isNot(AppColors.background));
      },
    );

    test('exposes the brand and accent colours through the scheme', () {
      final scheme = AppTheme.dark.colorScheme;

      expect(scheme.primary, AppColors.brand);
      expect(scheme.secondary, AppColors.accent);
      expect(scheme.error, AppColors.danger);
    });

    test('is built without throwing and has a usable text scale', () {
      final theme = AppTheme.dark;

      // Touching the getters forces construction of the nested component
      // themes, so a malformed one would surface here rather than on a screen.
      expect(theme.textTheme.titleLarge, isNotNull);
      expect(theme.textTheme.bodyMedium, isNotNull);
      expect(theme.cardTheme, isNotNull);
      expect(theme.scaffoldBackgroundColor, isNotNull);
    });

    test('keeps the shared corner radii', () {
      expect(AppTheme.radiusLarge, 16.0);
      expect(AppTheme.radiusMedium, 12.0);
      expect(AppTheme.radiusSmall, 8.0);
    });
  });

  group('AppColors', () {
    /// Every colour the app names by hand, not through the scheme. A change to
    /// this list is a reminder that the new colour also needs an opaque alpha.
    const Map<String, Color> palette = {
      'brand': AppColors.brand,
      'accent': AppColors.accent,
      'success': AppColors.success,
      'warning': AppColors.warning,
      'danger': AppColors.danger,
      'background': AppColors.background,
      'surface': AppColors.surface,
      'surfaceHigh': AppColors.surfaceHigh,
      'aiBubble': AppColors.aiBubble,
      'userBubble': AppColors.userBubble,
    };

    test('every colour is fully opaque', () {
      palette.forEach((name, colour) {
        expect(colour.a, 1.0, reason: '$name must not be translucent');
      });
    });

    test('the brand and the AI accent are the documented values', () {
      // The two colours the product is specified in. Pinned so a palette edit
      // is a deliberate act rather than an accident.
      expect(AppColors.brand, const Color(0xFF6366F1));
      expect(AppColors.accent, const Color(0xFF22D3EE));
    });

    test('surfaces are stepped so elevation reads without shadows', () {
      // background < surface < surfaceHigh. Kept as an ordering rather than
      // exact values so the palette can be re-tuned without breaking the
      // relationship the theme depends on.
      double luma(Color c) => c.computeLuminance();

      expect(luma(AppColors.surface), greaterThan(luma(AppColors.background)));
      expect(luma(AppColors.surfaceHigh), greaterThan(luma(AppColors.surface)));
    });
  });
}
