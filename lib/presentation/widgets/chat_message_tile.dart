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
import '../../core/theme/motion.dart';
import '../../domain/models/models.dart';

/// Renders a single [ChatMessage] as an avatar-and-bubble row.
///
/// Text stays inside a [SelectableText] so long-press to copy, and the
/// selectable-region behaviour users already rely on, is unchanged.
class ChatMessageTile extends StatefulWidget {
  const ChatMessageTile({super.key, required this.message});

  final ChatMessage message;

  @override
  State<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends State<ChatMessageTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.message.role == 'user';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final maxWidth = MediaQuery.of(context).size.width * 0.85;

    return FadeSlideIn(
      duration: const Duration(milliseconds: 400),
      dy: 0.04,
      child: ScaleTransition(
        scale: CurvedAnimation(
          parent: _controller,
          curve: AppMotion.enter,
          reverseCurve: AppMotion.exit,
        ),
        child: _buildMessage(isUser, scheme, text, maxWidth, theme),
      ),
    );
  }

  Widget _buildMessage(
    bool isUser,
    ColorScheme scheme,
    TextTheme text,
    double maxWidth,
    ThemeData theme,
  ) {
    final bubble = _buildBubble(isUser, scheme, text, maxWidth, theme);

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AssistantAvatar(),
        const SizedBox(width: 10),
        Flexible(child: bubble),
      ],
    );
  }

  Widget _buildBubble(
    bool isUser,
    ColorScheme scheme,
    TextTheme text,
    double maxWidth,
    ThemeData theme,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(maxWidth: maxWidth),
      decoration: BoxDecoration(
        color: isUser ? AppColors.userBubble : AppColors.aiBubble,
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        border: isUser
            ? null
            : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        boxShadow: isUser
            ? [
                BoxShadow(
                  color: AppColors.brand.withValues(alpha: 0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                  spreadRadius: 0,
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                  spreadRadius: 0,
                ),
              ],
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
                  Text(_formatTime(widget.message.timestamp), style: text.labelSmall),
              ],
            ),
          if (!isUser) const SizedBox(height: 6),
          if (isUser)
            SelectableText(widget.message.content, style: text.bodyLarge)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                MarkdownBody(
                  data: widget.message.content,
                  selectable: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(theme),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () async {
                      await Clipboard.setData(
                        ClipboardData(text: widget.message.content),
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
                _formatTime(widget.message.timestamp),
                style: text.labelSmall?.copyWith(color: Colors.white70),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A zero timestamp means "not recorded"; there is nothing honest to show.
  bool get _hasTime => widget.message.timestamp > 0;

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
///
/// [theme] is passed through from [_buildMessage] so MarkdownStyleSheet can
/// read the app's colour tokens instead of inventing its own defaults.
class _AssistantAvatar extends StatefulWidget {
  @override
  State<_AssistantAvatar> createState() => _AssistantAvatarState();
}

class _AssistantAvatarState extends State<_AssistantAvatar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
            boxShadow: [
              BoxShadow(
                color: AppColors.accent.withValues(
                  alpha: 0.15 + (0.1 * _pulseController.value),
                ),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const Icon(
            Icons.psychology,
            size: 16,
            color: AppColors.accent,
          ),
        );
      },
    );
  }
}
