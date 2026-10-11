/// The "there is nothing here yet" shape, shared by every list-driven screen.
///
/// Before this existed each screen had invented its own: a bare centred string
/// on Memory, a grey icon on Activity, nothing at all on Tools. They all read
/// as a broken screen rather than an intentional state, because the one thing
/// they share — no rows — is also what a failed build looks like. A single
/// component makes "empty" a designed state everywhere: glyph, headline, one
/// sentence of explanation, and at most one action.
///
/// The action is optional on purpose. Offering a button that has nowhere
/// useful to go is worse than offering none.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Icon + headline + one line of explanation + an optional single action.
class ScreenEmptyState extends StatelessWidget {
  const ScreenEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.actionIcon,
    this.tint,
    this.compact = false,
  });

  /// Glyph shown inside the tinted circle.
  final IconData icon;

  /// One short line: what this screen is for, in the user's terms.
  final String title;

  /// One sentence. Explains, never repeats the headline.
  final String message;

  /// Label of the single call to action, if this empty state has one.
  final String? actionLabel;

  /// Invoked when [actionLabel] is set.
  final VoidCallback? onAction;

  /// Leading glyph for the action button.
  final IconData? actionIcon;

  /// Circle/icon tint. Defaults to the scheme primary; pass a semantic colour
  /// (success, warning, danger) when the empty state is reporting something
  /// other than "you have not done this yet".
  final Color? tint;

  /// Tightens the layout for use *inside* a scroll view, where the centred
  /// full-height treatment would push the surrounding content off screen.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colour = tint ?? scheme.primary;
    final hasAction = actionLabel != null && onAction != null;

    return Padding(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 20)
          : const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 56 : 72,
            height: compact ? 56 : 72,
            decoration: BoxDecoration(
              color: colour.withValues(alpha: 0.10),
              shape: BoxShape.circle,
              border: Border.all(
                color: colour.withValues(alpha: 0.26),
                width: 1.5,
              ),
            ),
            child: Icon(icon, size: compact ? 26 : 34, color: colour),
          ),
          SizedBox(height: compact ? 14 : 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (hasAction) ...[
            SizedBox(height: compact ? 16 : 24),
            FilledButton.icon(
              onPressed: onAction,
              icon: Icon(actionIcon ?? Icons.arrow_forward, size: 18),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// The companion state: work is in progress, and the user should be able to
/// tell it apart from an empty list.
///
/// A spinner alone says "something is happening somewhere"; a spinner with a
/// label says what. This is deliberately plain — no shimmer skeleton, because
/// every list that uses it resolves in well under a frame or two and a skeleton
/// that flashes in and out reads as a glitch.
class ScreenLoadingState extends StatelessWidget {
  const ScreenLoadingState({super.key, this.label = 'Loading…'});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
