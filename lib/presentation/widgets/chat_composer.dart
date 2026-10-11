/// The composer bar: attachments, text field, microphone, and send/stop.
///
/// Extracted so `chat_screen.dart` keeps its state and the bar keeps its
/// layout. The bar reads emptiness straight off the [TextEditingController]
/// with a [ValueListenableBuilder] instead of being told: rebuilding the whole
/// chat screen on every keystroke was the previous behaviour and it made
/// typing in a long transcript feel like it lagged.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';

/// The raised composer at the bottom of the chat screen.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
    required this.onAttachImage,
    required this.onAttachDocument,
    required this.onVoice,
    required this.imageTooltip,
    required this.documentTooltip,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// True while a reply streams or a cloud turn is in flight. Drives both the
  /// send/stop swap and whether Send is actionable.
  final bool isGenerating;

  /// Sends a turn. [text] is non-null only when the message came from the
  /// keyboard's send action, which carries the committed string with it; the
  /// send button passes null so the screen falls back to the controller's own
  /// text, matching what the caller typed.
  final ValueChanged<String?> onSend;

  final VoidCallback onStop;
  final VoidCallback onAttachImage;
  final VoidCallback onAttachDocument;
  final VoidCallback onVoice;

  final String imageTooltip;
  final String documentTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: ValueListenableBuilder<String>(
          valueListenable: controller,
          builder: (context, value, _) {
            final hasText = value.trim().isNotEmpty;
            // Send is actionable for text; during generation the same slot
            // becomes Stop, which is always actionable.
            final canSend = hasText && !isGenerating;

            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _BarButton(
                  icon: Icons.add_photo_alternate_outlined,
                  tooltip: imageTooltip,
                  onPressed: onAttachImage,
                ),
                _BarButton(
                  icon: Icons.attach_file,
                  tooltip: documentTooltip,
                  onPressed: onAttachDocument,
                ),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 132),
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: onSend,
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                _BarButton(
                  icon: Icons.mic,
                  tooltip: 'Dictate',
                  onPressed: onVoice,
                ),
                const SizedBox(width: 4),
                _SendStopButton(
                  isGenerating: isGenerating,
                  enabled: canSend,
                  onSend: onSend,
                  onStop: onStop,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A flat, chrome-free icon button sized for the bar.
///
/// Smaller than the Material default (36 rather than 48) because the row holds
/// five controls; the surrounding touch target is padded back out instead of
/// the icon growing.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      iconSize: 21,
      splashRadius: 22,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      icon: Icon(icon),
    );
  }
}

/// The send/stop control.
///
/// The two states cross-fade rather than snapping, which is the whole point of
/// the swap: the button occupying the same spot in both states means the eye
/// does not have to re-find it mid-generation.
class _SendStopButton extends StatelessWidget {
  const _SendStopButton({
    required this.isGenerating,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final bool isGenerating;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      width: 44,
      height: 44,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.82, end: 1).animate(
              CurvedAnimation(parent: animation, curve: AppMotion.enter),
            ),
            child: child,
          ),
        ),
        child: isGenerating
            ? _RoundButton(
                key: const ValueKey('stop'),
                icon: Icons.stop,
                tooltip: 'Stop generating',
                background: scheme.error,
                foreground: scheme.onError,
                onPressed: onStop,
              )
            : _RoundButton(
                key: const ValueKey('send'),
                icon: Icons.send,
                tooltip: 'Send',
                // Low contrast when there is nothing to send, rather than
                // hidden: the slot stays put so the composer does not reflow
                // the first time a character is typed.
                background: enabled
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.14),
                foreground: enabled
                    ? scheme.onPrimary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.45),
                onPressed: enabled ? () => onSend(null) : null,
              ),
      ),
    );
  }
}

/// The circular button behind [_SendStopButton].
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: !disabled,
        label: tooltip,
        child: Material(
          color: background,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(
                  icon,
                  size: 20,
                  color: foreground,
                  // Redundant with the colour, but it is the difference
                  // between "disabled" and "faint" for anyone using a screen
                  // reader or a monochrome display.
                  semanticLabel: disabled ? '$tooltip (unavailable)' : tooltip,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
