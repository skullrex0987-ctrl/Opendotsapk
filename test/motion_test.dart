/// Tests for the shared motion language.
///
/// Motion is the easiest thing in an app to get quietly wrong: each screen
/// inventing its own curve is how eleven screens end up feeling like eleven
/// apps. These tests pin the pieces every screen depends on — the entrance
/// widget, the page transition and the timing budget — and they are written
/// defensively: they assert what is *guaranteed* (it builds, it settles, it does
/// not throw, the durations are what the design says) rather than pixel-exact
/// opacity values that would break on a framework tweak.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/theme/app_theme.dart';
import 'package:localmind/core/theme/motion.dart';

/// Hosts [AppMotion.fadeSlide] with a real controller so the transition is
/// driven exactly the way a pushed route would drive it.
class _FadeSlideHost extends StatefulWidget {
  const _FadeSlideHost({this.duration = AppMotion.base});

  final Duration duration;

  @override
  State<_FadeSlideHost> createState() => _FadeSlideHostState();
}

class _FadeSlideHostState extends State<_FadeSlideHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppMotion.fadeSlide(
      animation: _controller,
      child: const Text('slide-content'),
    );
  }
}

void main() {
  group('AppMotion constants', () {
    test('nothing routinely user-initiated exceeds 450ms', () {
      // The design rule: entrances are 200-300ms and nothing a person waits on
      // routinely is longer than 450ms.
      expect(AppMotion.instant, lessThan(AppMotion.fast));
      expect(AppMotion.fast, lessThan(AppMotion.base));
      expect(AppMotion.base, lessThan(AppMotion.slow));
      expect(AppMotion.slow.inMilliseconds, lessThanOrEqualTo(450));
    });

    test('exits are quicker than entrances', () {
      expect(
        AppMotion.base.inMilliseconds,
        greaterThan(AppMotion.fast.inMilliseconds),
      );
    });
  });

  group('AppMotion.fadeSlide', () {
    testWidgets('builds its child and completes without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _FadeSlideHost())),
      );

      expect(find.text('slide-content'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Run the transition to completion and pump once more so any deferred
      // ticker work is flushed before the tree is torn down.
      await tester.pump(AppMotion.base);
      await tester.pump(AppMotion.base);
      expect(tester.takeException(), isNull);
      expect(find.text('slide-content'), findsOneWidget);
    });

    testWidgets('is usable with a zero-duration animation', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: _FadeSlideHost(duration: Duration.zero)),
        ),
      );
      await tester.pump();
      expect(find.text('slide-content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FadeSlideIn', () {
    testWidgets('renders its child and settles', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FadeSlideIn(child: Text('card-content'))),
        ),
      );

      expect(find.text('card-content'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Past the default duration plus its (zero) delay.
      await tester.pump(AppMotion.slow);
      expect(find.text('card-content'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('supports a stagger without losing the child', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  FadeSlideIn(
                    delay: Duration(milliseconds: i * 60),
                    child: Text('row-$i'),
                  ),
              ],
            ),
          ),
        ),
      );

      for (var i = 0; i < 5; i++) {
        expect(find.text('row-$i'), findsOneWidget);
      }

      // Long enough for the last item's delay plus its duration.
      await tester.pump(AppMotion.slow);
      await tester.pump(AppMotion.slow);
      for (var i = 0; i < 5; i++) {
        expect(find.text('row-$i'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a stagger big enough to overrun the duration still builds', (
      tester,
    ) async {
      // The regression: the entrance used to clamp the *denominator* of the
      // delay/total ratio instead of the ratio itself, so any non-zero delay
      // produced an `Interval` begin above 1.0 and threw `begin <= 1.0` while
      // building. A delay larger than the duration is the clearest case.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                FadeSlideIn(
                  duration: AppMotion.fast,
                  delay: const Duration(seconds: 5),
                  child: const Text('long-delay'),
                ),
                FadeSlideIn(
                  duration: Duration.zero,
                  delay: const Duration(seconds: 5),
                  child: const Text('zero-duration'),
                ),
                const FadeSlideIn(child: Text('no-delay')),
              ],
            ),
          ),
        ),
      );

      await tester.pump(AppMotion.slow);
      expect(tester.takeException(), isNull);
      expect(find.text('long-delay'), findsOneWidget);
      expect(find.text('zero-duration'), findsOneWidget);
      expect(find.text('no-delay'), findsOneWidget);
    });

    testWidgets('a stagger ends fully opaque for every row', (tester) async {
      // A staggered row that never reaches opacity 1 is a row the user
      // believes is disabled.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < 4; i++)
                  FadeSlideIn(
                    delay: Duration(milliseconds: i * 60),
                    child: const Text('settled'),
                  ),
              ],
            ),
          ),
        ),
      );

      await tester.pump(AppMotion.slow);
      await tester.pump(AppMotion.slow);

      for (final element in find.text('settled').evaluate()) {
        final opacity = tester.widget<Opacity>(
          find.ancestor(
            of: find.byWidget(element.widget),
            matching: find.byType(Opacity),
          ),
        );
        expect(opacity.opacity, 1.0);
      }
    });

    testWidgets('accepts an explicit duration and dy', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FadeSlideIn(
              duration: const Duration(milliseconds: 250),
              dy: 0.05,
              child: Text('tuned'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('tuned'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppPageRoute', () {
    test('has a non-zero transition duration', () {
      final route = AppPageRoute<void>(builder: (_) => const SizedBox.shrink());

      expect(route.transitionDuration.inMicroseconds, greaterThan(0));
      expect(route.reverseTransitionDuration.inMicroseconds, greaterThan(0));
    });

    test('enters more slowly than it leaves', () {
      final route = AppPageRoute<void>(builder: (_) => const SizedBox.shrink());

      // Reversing is quicker than arriving: things that leave should not make
      // the user wait on the way out of a screen.
      expect(
        route.reverseTransitionDuration.inMicroseconds,
        lessThan(route.transitionDuration.inMicroseconds),
      );
    });

    testWidgets('pushes a screen that resolves without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                AppPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('pushed-page')),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(AppMotion.base);

      expect(find.text('pushed-page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('theme and motion together', () {
    testWidgets('a FadeSlideIn entrance works under AppTheme.dark', (
      tester,
    ) async {
      // The combination every screen actually uses; asserted together because
      // a theme that changed the surface stack could otherwise mask a broken
      // entrance or vice versa.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: FadeSlideIn(child: Text('themed'))),
        ),
      );
      await tester.pump(AppMotion.slow);
      expect(find.text('themed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
