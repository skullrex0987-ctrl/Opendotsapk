/// The cold-start screen: what a user sees before their first message.
///
/// There are two distinct versions of this state and they are deliberately not
/// the same widget with a flag. "No model loaded" means the app cannot answer
/// anything yet, and burying that behind a suggestion chip that silently does
/// nothing is how people conclude the app is broken. The no-model variant
/// therefore leads with one large action and no suggestions.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';

/// Designed empty state for the chat transcript.
class ChatEmptyState extends StatelessWidget {
  const ChatEmptyState({
    super.key,
    required this.modelLoaded,
    required this.onManageModels,
    required this.onSuggestion,
  });

  /// Whether a model is actually bound to the runtime.
  final bool modelLoaded;

  /// Opens Model Management.
  final VoidCallback onManageModels;

  /// Fills the composer with [String].
  final ValueChanged<String> onSuggestion;

  /// Prompts worth offering. Chosen to be things an on-device model is
  /// genuinely good at — reasoning, rewriting, summarising — rather than
  /// questions that need web access and would fail.
  static const List<(String, IconData)> _suggestions = [
    ('Explain a concept I find difficult, in plain language', Icons.school),
    ('Draft a short, polite reply to an email', Icons.edit_note),
    ('Compare two options and list the trade-offs', Icons.compare_arrows),
    ('Summarise a long document I attach', Icons.summarize),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            FadeSlideIn(child: _Emblem(modelLoaded: modelLoaded)),
            const SizedBox(height: 24),
            FadeSlideIn(
              delay: const Duration(milliseconds: 60),
              child: _Headline(modelLoaded: modelLoaded),
            ),
            const SizedBox(height: 10),
            FadeSlideIn(
              delay: const Duration(milliseconds: 120),
              child: Text(
                modelLoaded
                    ? 'Inference runs on this device through llama.cpp. '
                          'Your prompts never leave it unless you explicitly '
                          'choose a cloud model in the router.'
                    : 'Nothing is loaded yet, so there is nothing to talk to. '
                          'Pick a model first — it downloads once, then works '
                          'entirely offline.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (modelLoaded) ...[
              const SizedBox(height: 28),
              _Suggestions(onSuggestion: onSuggestion),
            ] else ...[
              const SizedBox(height: 28),
              FadeSlideIn(
                delay: const Duration(milliseconds: 180),
                child: FilledButton.icon(
                  onPressed: onManageModels,
                  icon: const Icon(Icons.download),
                  label: const Text('Choose a model'),
                ),
              ),
              const SizedBox(height: 10),
              FadeSlideIn(
                delay: const Duration(milliseconds: 240),
                child: TextButton(
                  onPressed: onManageModels,
                  child: const Text('Open Model Management'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The circle-and-glyph at the top of the empty state.
class _Emblem extends StatelessWidget {
  const _Emblem({required this.modelLoaded});

  final bool modelLoaded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = modelLoaded ? AppColors.brand : scheme.onSurfaceVariant;

    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        // A soft radial-ish falloff built from one flat fill plus a border:
        // gradients on a near-black page are cheap and this is the only place
        // in the app that earns one.
        color: tint.withValues(alpha: 0.10),
        shape: BoxShape.circle,
        border: Border.all(color: tint.withValues(alpha: 0.28), width: 1.5),
      ),
      child: Icon(
        modelLoaded ? Icons.forum : Icons.memory,
        size: 40,
        color: tint,
      ),
    );
  }
}

/// The headline line, plus the sub-line when there is no model.
class _Headline extends StatelessWidget {
  const _Headline({required this.modelLoaded});

  final bool modelLoaded;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          modelLoaded
              ? 'Ask anything — it never leaves your phone'
              : 'Download a model to start',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        if (!modelLoaded) ...[
          const SizedBox(height: 8),
          Text(
            'A few hundred megabytes to a few gigabytes, depending on the '
            'model you want.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// The tappable prompt suggestions.
///
/// Buttons, not chips: a chip reads as a filter and this is a shortcut that
/// fills the composer, so each one says so with a trailing arrow.
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < ChatEmptyState._suggestions.length; i++) ...[
          FadeSlideIn(
            delay: Duration(milliseconds: 180 + i * 70),
            child: _SuggestionTile(
              // Cap the stagger: a five-item list at 70 ms each is the ceiling
              // before the last chip feels late rather than choreographed.
              label: ChatEmptyState._suggestions[i].$1,
              icon: ChatEmptyState._suggestions[i].$2,
              onTap: () => onSuggestion(ChatEmptyState._suggestions[i].$1),
            ),
          ),
          if (i != ChatEmptyState._suggestions.length - 1)
            const SizedBox(height: 8),
        ],
        const SizedBox(height: 4),
        Align(
          child: Text(
            'Tap to fill the composer',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppTheme.radiusMedium);

    return Material(
      color: AppColors.surface,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: AppColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Icon(Icons.north_west, size: 14, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
