/// The header chip that reports what is actually in memory.
///
/// Split out of `chat_screen.dart` because the header is rebuilt on every
/// 50 ms token flush during generation; keeping the chip's own layout and
/// colour decisions here means the streaming path cannot accidentally reshape
/// it.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A tappable status pill shown on the right of the chat header.
///
/// It opens Model Management rather than merely displaying status, because
/// "which model am I on" and "change which model I am on" are the same question
/// for most people, and the previous grey text label answered neither.
class ChatStatusChip extends StatelessWidget {
  const ChatStatusChip({
    super.key,
    required this.loaded,
    required this.label,
    required this.onTap,
  });

  /// Whether a model is genuinely bound. Drives the colour.
  final bool loaded;

  /// Pre-truncated display text, e.g. `Qwen3.5 · GPU` or `No model loaded`.
  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Muted rather than the danger colour when empty: having no model loaded
    // is the first-run state, not an error, and painting it red made the cold
    // start look like a failure.
    final tint = loaded ? AppColors.success : scheme.onSurfaceVariant;
    final radius = BorderRadius.circular(AppTheme.radiusMedium);

    return Semantics(
      button: true,
      label: 'Model status: $label. Opens Model Management.',
      child: Material(
        color: tint.withValues(alpha: loaded ? 0.12 : 0.07),
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: tint.withValues(alpha: 0.32)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  loaded ? Icons.memory : Icons.cloud_download_outlined,
                  size: 14,
                  color: tint,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: tint, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
