/// First-run onboarding.
///
/// Three screens, and every one of them says something true about how the app
/// behaves. An onboarding that oversells privacy and then sends prompts to a
/// cloud API would be worse than none, so the copy matches the actual defaults:
/// on-device by default, cloud only if the user opts in.
///
/// The third page is the "ready" page and is the only one that commits
/// anything: [onboarding_done] is written there, exactly as before, and the
/// same code path is taken by Skip. A skip button that quietly did less than
/// the primary action would make the three choices at the bottom equivalent
/// when they are not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/motion.dart';
import '../providers/providers.dart';
import 'models_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  /// Peek factor: the next page shows a sliver of itself, which is the only
  /// affordance that says "there is more to the right" on a gesture-driven
  /// screen where nothing else moves until you commit to a swipe.
  final PageController _pages = PageController(viewportFraction: 0.92);

  int _index = 0;

  /// Kept as a const list so the three slides are the same widget instances
  /// across rebuilds and the controller's page cache is not thrown away by
  /// every setState from the indicator.
  static const List<_Slide> _slides = [
    _Slide(
      icon: Icons.shield_outlined,
      title: 'Nothing leaves by default',
      body:
          'The assistant runs on this device. Your messages, notes and memory '
          'are stored here and encrypted at rest.\n\n'
          'The only tool that touches the network is web search, and only if '
          'you turn it on.',
    ),
    _Slide(
      icon: Icons.memory,
      title: 'Download a model to begin',
      body:
          'LocalMind is the engine; the model is the brain. You pick one and '
          'the app downloads it.\n\n'
          'Start with Qwen2.5 0.5B (~397 MB) on a mid-range phone, or '
          'SmolLM2 360M if storage is tight.',
    ),
    _Slide(
      icon: Icons.cloud_queue,
      title: 'Cloud is optional, and yours',
      body:
          'If you ever want a bigger model, add your own API key. It is kept '
          "in this device's hardware keystore and never uploaded.\n\n"
          'You choose when cloud is used — or forbid it entirely with private '
          'mode.',
    ),
  ];

  bool get _isLast => _index == _slides.length - 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pages,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, index) {
                  final slide = _slides[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FadeSlideIn(
                      // Each slide arrives on its own, not on page change:
                      // the entrance animation belongs to the screen
                      // appearing, and replaying it mid-swipe makes the
                      // gesture feel like it is fighting the UI.
                      duration: AppMotion.slow,
                      child: slide,
                    ),
                  );
                },
              ),
            ),
            _PageDots(
              count: _slides.length,
              index: _index,
              activeColor: scheme.primary,
              inactiveColor: scheme.onSurfaceVariant.withValues(alpha: 0.3),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Row(
                children: [
                  if (!_isLast) ...[
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _back,
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _next,
                      child: Text(_isLast ? 'Get started' : 'Next'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _back() async {
    if (_index == 0) return;
    await _pages.previousPage(
      duration: AppMotion.base,
      curve: AppMotion.standard,
    );
  }

  Future<void> _next() async {
    if (!_isLast) {
      await _pages.nextPage(
        duration: AppMotion.base,
        curve: AppMotion.standard,
      );
      return;
    }

    await _finish();
  }

  /// Commit first-run and enter the app.
  ///
  /// Shared by the primary button and by Skip, so both write the same flag,
  /// at the same point, and land on the same destination. The model picker is
  /// the destination because without a model the app cannot answer anything —
  /// landing on an empty chat would be a dead end.
  Future<void> _finish() async {
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('onboarding_done', true);

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      AppPageRoute(builder: (_) => const ModelsScreen()),
    );
  }
}

/// The animated page indicator.
///
/// Width, not colour, is the active signal: at 8dp wide the three dots read as
/// a row of dots regardless of colour, and the elongation is what actually
/// marks the current page.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.index,
    required this.activeColor,
    required this.inactiveColor,
  });

  final int count;
  final int index;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == index;
        return AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 8,
          width: active ? 22 : 8,
          decoration: BoxDecoration(
            color: active ? activeColor : inactiveColor,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

class _Slide extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Slide({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // One accent moment on the first slide only would be arbitrary;
            // instead the emblem carries the brand colour and the glyph inside
            // it carries the step's meaning, which differs per slide.
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.30),
                  width: 1.5,
                ),
              ),
              child: Icon(icon, size: 38, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 28),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 14),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}