/// One row of the chat transcript.
///
/// Replaces the undifferentiated bubble that every message used to get. The two
/// roles are separated by colour, alignment, and an avatar on the assistant
/// side, so a long transcript can be scanned without reading it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../core/theme/app_theme.dart';
import '../../domain/models/models.dart';

/// Renders a single [ChatMessage] as an avatar-and-bubble row.
///
/// Text stays inside a [SelectableText] so long-press to copy, and the
/// selectable-region behaviour users already rely on, is unchanged.
class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final maxWidth = MediaQuery.of(context).size.width * 0.85;

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: BoxDecoration(
        color: isUser ? AppColors.userBubble : AppColors.aiBubble,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        // The AI bubble sits on the page background, so it needs a hairline to
        // read as a surface; the user bubble is brand-filled and needs none.
        border: isUser
            ? null
            : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isUser)
            Row(
              children: [
                Text(
                  'LocalMind',
                  style: text.labelMedium?.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_hasTime)
                  Text(_formatTime(message.timestamp), style: text.labelSmall),
              ],
            ),
          if (!isUser) const SizedBox(height: 6),
          // Assistant replies are Markdown: a coding answer is mostly fenced
          // code blocks, and plain text renders them as an unreadable wall of
          // backticks. `MarkdownStyle.fromTheme` keeps it on our palette
          // instead of the package's black-on-white default. The user's own
          // message stays a SelectableText — there is nothing to render.
          if (isUser)
            SelectableText(message.content, style: text.bodyLarge)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MarkdownBody(
                  data: message.content,
                  selectable: true,
                  styleSheet: MarkdownStyle.fromTheme(theme),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: message.content),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(
                            const SnackBar(
                              content: Text('Copied to clipboard'),
                            ),
                          );
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.copy_rounded, size: 14),
                    ),
                  ),
                ),
              ],
            ),
          if (isUser && _hasTime) ...[
            const SizedBox(height: 5),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatTime(message.timestamp),
                style: text.labelSmall?.copyWith(color: Colors.white70),
              ),
            ),
          ],
        ],
      ),
    );

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AssistantAvatar(),
        const SizedBox(width: 8),
        Flexible(child: bubble),
      ],
    );
  }

  /// A zero timestamp means "not recorded"; there is nothing honest to show.
  bool get _hasTime => message.timestamp > 0;

  /// `HH:MM` in device-local time.
  ///
  /// Formatted by hand rather than through `intl` so the transcript needs no
  /// additional dependency for the one format it needs.
  static String _formatTime(int millisSinceEpoch) {
    final at = DateTime.fromMillisecondsSinceEpoch(millisSinceEpoch);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}';
  }
}

/// The assistant's leading glyph.
///
/// Small, low-contrast, and cyan: it marks authorship without turning every
/// reply into an avatar that competes with the text.
class _AssistantAvatar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
      ),
      child: const Icon(Icons.psychology, size: 16, color: AppColors.accent),
    );
  }
}
