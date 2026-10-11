import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/providers/providers.dart';
import 'presentation/screens/onboarding_screen.dart';
import 'presentation/screens/main_screen.dart';
import 'presentation/widgets/biometric_gate.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/motion.dart';

/// Root application widget.
class LocalMindApp extends StatelessWidget {
  const LocalMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      // One theme for the whole app — colours, type, shape, and component
      // defaults all live in AppTheme so no screen invents its own.
      theme: AppTheme.dark,
      home: const SplashScreen(),
    );
  }
}

/// Brief splash, then first-run onboarding or the main shell.
///
/// The splash doubles as the app's entrance animation: the logo settles in,
/// the wordmark follows, and the dots pulse while settings are read. The wait
/// is *whichever is longer* — the minimum animation time or the settings read —
/// so a returning user is never held on a finished animation, and a first run
/// never pops the onboarding route before its flag is known.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.slow + const Duration(milliseconds: 250),
  )..forward();

  /// Logo: settles from slightly small and offset, so the first frame already
  /// reads as motion rather than a static image that then cuts away.
  late final Animation<double> _logoScale = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.55, curve: AppMotion.enter),
  ).drive(Tween(begin: 0.82, end: 1.0));

  late final Animation<double> _logoOpacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.45, curve: AppMotion.enter),
  );

  /// Wordmark and tagline trail the logo by ~180ms so the eye lands on the
  /// mark first.
  late final Animation<double> _textOpacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.28, 0.8, curve: AppMotion.enter),
  );

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // Floor on how long the splash is shown — short enough that a returning
    // user barely notices, long enough that the entrance does not look like a
    // glitch.
    const minimumSplash = Duration(milliseconds: 1500);
    final sw = Stopwatch()..start();

    final settings = ref.read(settingsProvider);

    // Give the settings notifier a moment to read the database; the splash is
    // the only place where a first-run flag can be checked safely.
    var seenOnboarding = settings['onboarding_done'] == true;
    for (var i = 0; i < 20 && !seenOnboarding; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      seenOnboarding = ref.read(settingsProvider)['onboarding_done'] == true;
      if (seenOnboarding) break;
    }

    final remaining = minimumSplash - sw.elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      AppPageRoute(
        builder: (_) =>
            seenOnboarding ? const _LockedShell() : const OnboardingScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.35),
            radius: 0.9,
            colors: [Color(0xFF1B1F44), AppColors.background],
            stops: [0, 0.75],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FadeTransition(
                opacity: _logoOpacity,
                child: ScaleTransition(
                  scale: _logoScale,
                  child: Container(
                    padding: const EdgeInsets.all(26),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.brand.withValues(alpha: 0.45),
                          blurRadius: 44,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.psychology_rounded,
                      size: 62,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 26),
              FadeTransition(
                opacity: _textOpacity,
                child: Column(
                  children: [
                    const Text(
                      AppConstants.appName,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Your Private AI Agent',
                      style: TextStyle(
                        fontSize: 15,
                        letterSpacing: 0.2,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 44),
                    const _PulsingDots(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three dots that breathe in sequence while the app boots.
///
/// A `CircularProgressIndicator` spins at a constant rate, which reads as
/// "still working" forever; a staggered pulse reads as activity and stops
/// cleanly the moment the route is replaced.
class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Each dot peaks a third of a cycle after the previous one.
            final phase = (_controller.value - i * 0.2) % 1.0;
            final t = Curves.easeInOut.transform(
              phase < 0.5 ? phase * 2 : (1 - phase) * 2,
            );
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Opacity(
                opacity: 0.3 + 0.7 * t,
                child: Transform.translate(
                  offset: Offset(0, -3 * t),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AppColors.brand,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// The main shell behind the optional biometric lock.
///
/// Stateful so it can push the lock state down to the platform window: while
/// the lock is on the app must not be drawn into the recents thumbnail.
class _LockedShell extends ConsumerStatefulWidget {
  const _LockedShell();

  @override
  ConsumerState<_LockedShell> createState() => _LockedShellState();
}

class _LockedShellState extends ConsumerState<_LockedShell> {
  /// Last value pushed to the platform, so the channel is only hit on change.
  bool? _secureApplied;

  void _syncSecureWindow(bool enabled) {
    if (_secureApplied == enabled) return;
    _secureApplied = enabled;
    if (enabled) {
      SecureScreen.enable();
    } else {
      SecureScreen.disable();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final lockOn = settings['biometric_lock'] as bool? ?? false;

    // FLAG_SECURE hides the app from screenshots and the Android 13+ recents
    // thumbnail. Tie it to the lock so it is only on when the user asked for
    // privacy, and pushed after the frame to keep build side-effect free.
    if (_secureApplied != lockOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncSecureWindow(lockOn);
      });
    }

    return BiometricGate(
      enabled: lockOn,
      // Way out of the fail-closed screen: the user explicitly drops the lock.
      onDisableLock: () => ref
          .read(settingsProvider.notifier)
          .updateSetting('biometric_lock', false),
      child: const MainScreen(),
    );
  }
}
