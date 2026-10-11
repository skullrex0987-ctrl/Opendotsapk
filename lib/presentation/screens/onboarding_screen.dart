/// First-run onboarding.
///
/// Three screens, and every one of them says something true about how the app
/// behaves. An onboarding that oversells privacy and then sends prompts to a
/// cloud API would be worse than none, so the copy matches the actual defaults:
/// on-device by default, cloud only if the user opts in.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import 'models_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _index = i),
                children: const [
                  _Slide(
                    icon: Icons.shield_outlined,
                    title: 'Nothing leaves by default',
                    body:
                        'The assistant runs on this device. Your messages, '
                        'notes and memory are stored here and encrypted at '
                        'rest.\n\n'
                        'The only tool that touches the network is web search, '
                        'and only if you turn it on.',
                  ),
                  _Slide(
                    icon: Icons.memory,
                    title: 'Download a model to begin',
                    body:
                        'LocalMind is the engine; the model is the brain. '
                        'You pick one and the app downloads it.\n\n'
                        'Start with Qwen2.5 0.5B (~397 MB) on a mid-range '
                        'phone, or SmolLM2 360M if storage is tight.',
                  ),
                  _Slide(
                    icon: Icons.cloud_queue,
                    title: 'Cloud is optional, and yours',
                    body:
                        'If you ever want a bigger model, add your own API '
                        'key. It is kept in this device\'s hardware keystore '
                        'and never uploaded.\n\n'
                        'You choose when cloud is used — or forbid it '
                        'entirely with private mode.',
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final active = i == _index;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  height: 8,
                  width: active ? 20 : 8,
                  decoration: BoxDecoration(
                    color: active
                        ? Theme.of(context).colorScheme.primary
                        : Colors.grey[700],
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(_index == 2 ? 'Get started' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _next() async {
    if (_index < 2) {
      await _pages.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }

    await ref
        .read(settingsProvider.notifier)
        .updateSetting('onboarding_done', true);

    if (!mounted) return;

    // Straight to the model picker: without a model the app cannot answer
    // anything, so landing on an empty chat would be a dead end.
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const ModelsScreen()));
  }
}

class _Slide extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Slide({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 28),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: Colors.grey[400],
            ),
          ),
        ],
      ),
    );
  }
}
