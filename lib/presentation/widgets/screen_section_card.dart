/// Section chrome shared by the settings-shaped screens.
///
/// Two pieces, both of which had been re-implemented slightly differently on
/// every screen: a titled group and the tinted circle that every settings row
/// uses as its leading icon. Consistency here is not cosmetic — a list of rows
/// with eight different leading treatments reads as eight different apps, and
/// the eye stops trusting that the leading glyph means anything.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A titled, sub-titled card group.
///
/// The header sits outside the card rather than inside it so a long list of
/// sections stays scannable: the eye finds headers first, then the card they
/// describe. [child] is expected to lay out its own rows; the card supplies the
/// surface, the radius and the spacing between the header and the content.
class ScreenSection extends StatelessWidget {
  const ScreenSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
  });

  /// Short, stable section name: "Privacy & security", not a sentence.
  final String title;

  /// One line saying what the section controls. Optional but always worth it:
  /// most rows here have non-obvious consequences.
  final String? subtitle;

  /// Optional right-aligned header widget (a counter, a status).
  final Widget? trailing;

  final Widget child;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.labelLarge),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: padding, child: child),
        ),
      ],
    );
  }
}

/// The leading treatment for a settings row: a tinted circle around a glyph.
///
/// The tint is the primary colour at low opacity by default so a screen of
/// these reads as one system. Pass [color] to give a row its own semantics —
/// danger for the erase action, success for something already enabled.
class ScreenRowIcon extends StatelessWidget {
  const ScreenRowIcon({
    super.key,
    required this.icon,
    this.color,
    this.size = 38,
  });

  final IconData icon;

  /// Circle and glyph colour. Defaults to the scheme primary.
  final Color? color;

  /// Outer diameter. 38 fits a standard [ListTile]; 32 suits dense rows.
  final double size;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.primary;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size * 0.48, color: tint),
    );
  }
}

/// A hairline between rows inside a [ScreenSection] card.
///
/// Inset on the left so it lines up with the row text rather than the row
/// icon, which is what makes a stack of rows read as one list instead of a
/// stack of unrelated cards.
class ScreenRowDivider extends StatelessWidget {
  const ScreenRowDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Divider(height: 1, indent: 8, endIndent: 8);
  }
}