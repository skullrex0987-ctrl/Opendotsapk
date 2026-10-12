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
class ChatComposer extends StatefulWidget {
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
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _focusController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  late final AnimationController _sendPulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChange);
    widget.controller.addListener(_onTextChange);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    widget.controller.removeListener(_onTextChange);
    _focusController.dispose();
    _sendPulseController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (widget.focusNode.hasFocus) {
      _focusController.forward();
    } else {
      _focusController.reverse();
    }
  }

  void _onTextChange() {
    if (widget.controller.text.trim().isNotEmpty && !widget.isGenerating) {
      _sendPulseController.forward();
    } else {
      _sendPulseController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _focusController,
      builder: (context, child) {
        final borderWidth = 1.5 + (_focusController.value * 1.5);
        final glowOpacity = _focusController.value * 0.15;

        return Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(
            color: AppColors.surfaceHigh,
            border: Border(
              top: BorderSide(
                color: widget.focusNode.hasFocus
                    ? scheme.primary.withValues(
                        alpha: 0.5 + 0.3 * _focusController.value,
                      )
                    : scheme.outlineVariant.withValues(alpha: 0.5),
                width: borderWidth,
              ),
            ),
            boxShadow: [
              if (widget.focusNode.hasFocus)
                BoxShadow(
                  color: scheme.primary.withValues(alpha: glowOpacity),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: const Offset(0, -4),
                ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final hasText = widget.controller.text.trim().isNotEmpty;
                final canSend = hasText && !widget.isGenerating;

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _BarButton(
                      icon: Icons.add_photo_alternate_outlined,
                      tooltip: widget.imageTooltip,
                      onPressed: widget.onAttachImage,
                    ),
                    _BarButton(
                      icon: Icons.attach_file,
                      tooltip: widget.documentTooltip,
                      onPressed: widget.onAttachDocument,
                    ),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 132),
                        child: TextField(
                          controller: widget.controller,
                          focusNode: widget.focusNode,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: widget.onSend,
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
                      onPressed: widget.onVoice,
                    ),
                    const SizedBox(width: 4),
                    _SendStopButton(
                      isGenerating: widget.isGenerating,
                      enabled: canSend,
                      onSend: widget.onSend,
                      onStop: widget.onStop,
                      pulseController: _sendPulseController,
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// A flat, chrome-free icon button sized for the bar.
///
/// Smaller than the Material default (36 rather than 48) because the row holds
/// five controls; the surrounding touch target is padded back out instead of
/// the icon growing.
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  );

  bool _isHovered = false;

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _pressController.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    _pressController.reverse();
  }

  void _handleTapCancel() {
    _pressController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _pressController,
      builder: (context, child) {
        final scale = 1.0 - (_pressController.value * 0.12);
        return Transform.scale(
          scale: scale,
          child: MouseRegion(
            onEnter: (_) => setState(() => _isHovered = true),
            onExit: (_) => setState(() => _isHovered = false),
            child: GestureDetector(
              onTapDown: _handleTapDown,
              onTapUp: _handleTapUp,
              onTapCancel: _handleTapCancel,
              onTap: widget.onPressed,
              child: Tooltip(
                message: widget.tooltip,
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isHovered
                        ? scheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    border: _isHovered
                        ? Border.all(
                            color: scheme.primary.withValues(alpha: 0.3),
                            width: 1,
                          )
                        : null,
                  ),
                  child: Icon(
                    widget.icon,
                    size: 21,
                    color: _isHovered
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The send/stop control.
///
/// The two states cross-fade rather than snapping, which is the whole point of
/// the swap: the button occupying the same spot in both states means the eye
/// does not have to re-find it mid-generation.
class _SendStopButton extends StatefulWidget {
  const _SendStopButton({
    required this.isGenerating,
    required this.enabled,
    required this.onSend,
    required this.onStop,
    required this.pulseController,
  });

  final bool isGenerating;
  final bool enabled;

  /// Same signature as [ChatComposer.onSend]: the keyboard's submit action
  /// carries the committed string, the send button passes null so the screen
  /// falls back to the controller's own text. Typed as VoidCallback this did
  /// not compile at either end — the caller passes a `String?` and this file
  /// called it with `null`.
  final ValueChanged<String?> onSend;
  final VoidCallback onStop;
  final AnimationController pulseController;

  @override
  State<_SendStopButton> createState() => _SendStopButtonState();
}

class _SendStopButtonState extends State<_SendStopButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  void _handleTapDown(TapDownDetails _) {
    _scaleController.forward();
  }

  void _handleTapUp(TapUpDetails _) {
    _scaleController.reverse();
  }

  void _handleTapCancel() {
    _scaleController.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = !widget.enabled && !widget.isGenerating;

    return AnimatedBuilder(
      animation: Listenable.merge([widget.pulseController, _scaleController]),
      builder: (context, child) {
        final pressScale = 1.0 - (_scaleController.value * 0.15);
        final pulseScale = 1.0 + (widget.pulseController.value * 0.1);
        final combinedScale = pressScale * pulseScale;

        return Transform.scale(
          scale: combinedScale,
          child: SizedBox(
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
              child: widget.isGenerating
                  ? _RoundButton(
                      key: const ValueKey('stop'),
                      icon: Icons.stop,
                      tooltip: 'Stop generating',
                      background: scheme.error,
                      foreground: scheme.onError,
                      onPressed: widget.onStop,
                      pulseController: widget.pulseController,
                    )
                  : _RoundButton(
                      key: const ValueKey('send'),
                      icon: Icons.send,
                      tooltip: 'Send',
                      // Low contrast when there is nothing to send, rather than
                      // hidden: the slot stays put so the composer does not reflow
                      // the first time a character is typed.
                      background: widget.enabled
                          ? scheme.primary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.14),
                      foreground: widget.enabled
                          ? scheme.onPrimary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.45),
                      onPressed: widget.enabled
                          ? () => widget.onSend(null)
                          : null,
                      pulseController: widget.pulseController,
                    ),
            ),
          ),
        );
      },
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
    required this.pulseController,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback? onPressed;
  final AnimationController pulseController;

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;

    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, child) {
        final pulseValue = pulseController.value;
        final hasPulse = pulseValue > 0;

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
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (hasPulse && !disabled)
                          Transform.scale(
                            scale: 1.0 + (pulseValue * 0.3),
                            child: Opacity(
                              opacity: (1.0 - pulseValue) * 0.5,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: foreground,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Icon(
                          icon,
                          size: 20,
                          color: foreground,
                          semanticLabel: disabled
                              ? '$tooltip (unavailable)'
                              : tooltip,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
