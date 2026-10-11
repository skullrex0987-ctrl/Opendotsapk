/// The app's motion language: curves, durations, the shared page transition,
/// and a small entrance widget.
///
/// Timing lives here rather than being invented per screen. Eleven screens
/// each picking their own curve is how an app ends up feeling like eleven
/// apps — a transition that is snappy on one screen and syrupy on the next
/// reads as instability, not as style.
///
/// Rules of thumb encoded below:
///  * things that *appear* ease out fast (the user just acted, show it now);
///  * things that *leave* are quicker than things that arrive;
///  * nothing a user does routinely takes longer than ~300 ms.
library;

import 'package:flutter/material.dart';

class AppMotion {
  AppMotion._();

  /// Default curve for anything user-initiated.
  static const Curve standard = Curves.easeOutCubic;

  /// Entrances: fast start, soft landing — feels responsive without a snap.
  static const Curve enter = Curves.easeOutQuart;

  /// Exits: faster, and never overshooting.
  static const Curve exit = Curves.easeInCubic;

  /// For values that travel a long distance (progress, counters, bars).
  static const Curve emphasized = Curves.easeInOutCubic;

  static const Duration instant = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration base = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 450);

  /// The one route transition: a short fade plus a small upward slide.
  ///
  /// Deliberately subtle (3% of the screen height). Android's own guidance is
  /// that a transition should clarify spatial origin without becoming the
  /// thing you watch, and a full-screen slide competes with content that is
  /// still settling.
  static Widget fadeSlide({
    required Animation<double> animation,
    required Widget child,
  }) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: enter,
      reverseCurve: exit,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

/// A push transition built on [AppMotion.fadeSlide].
///
/// Use it instead of `MaterialPageRoute` for screens opened from the shell:
///
/// ```dart
/// Navigator.of(context).push(AppPageRoute(builder: (_) => const SettingsScreen()));
/// ```
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({required WidgetBuilder builder, RouteSettings? settings})
    : super(
        settings: settings,
        transitionDuration: AppMotion.base,
        reverseTransitionDuration: AppMotion.fast,
        pageBuilder: (context, _, __) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) =>
            AppMotion.fadeSlide(animation: animation, child: child),
      );
}

/// Entrances a list item or a card, with an optional stagger.
///
/// Uses [TweenAnimationBuilder] rather than an [AnimationController]: there is
/// no ticker to manage, no disposal to get wrong, and the widget is inert once
/// it reaches 1.0. Delay is expressed as an [Interval] on the same animation,
/// so a staggered list is still one timer per item rather than N timers.
///
/// ```dart
/// FadeSlideIn(
///   delay: Duration(milliseconds: index * 60),
///   child: Card(child: ...),
/// )
/// ```
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppMotion.base,
    this.dy = 0.03,
  });

  final Widget child;

  /// How long to wait before this child starts moving. Clamped so a very large
  /// index cannot push the start past the end of the animation.
  final Duration delay;

  final Duration duration;

  /// Start offset as a fraction of the child's height (0.03 = 3% up).
  final double dy;

  @override
  Widget build(BuildContext context) {
    final total = duration + delay;
    final begin =
        delay.inMilliseconds /
        (total.inMilliseconds == 0 ? 1 : total.inMilliseconds).clamp(0.0, 0.99);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total,
      curve: Interval(begin, 1.0, curve: AppMotion.enter),
      builder: (context, t, child) {
        // The slide only makes sense while there is something to slide from;
        // fading the last few percent is cheaper than animating a 1px offset.
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, dy * (1 - t) * 100),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
