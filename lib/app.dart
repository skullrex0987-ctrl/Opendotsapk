import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/providers/providers.dart';
import 'presentation/screens/onboarding_screen.dart';
import 'presentation/screens/main_screen.dart';
import 'presentation/widgets/biometric_gate.dart';
import 'core/constants/app_constants.dart';

/// Root application widget.
class LocalMindApp extends StatelessWidget {
  const LocalMindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppConstants.primaryColor,
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

/// Brief splash, then first-run onboarding or the main shell.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    final settings = ref.read(settingsProvider);

    // Give the settings notifier a moment to read the database; the splash is
    // the only place where a first-run flag can be checked safely.
    var seenOnboarding = settings['onboarding_done'] == true;
    for (var i = 0; i < 10 && !seenOnboarding; i++) {
      await Future.delayed(const Duration(milliseconds: 150));
      seenOnboarding = ref.read(settingsProvider)['onboarding_done'] == true;
      if (seenOnboarding) break;
    }

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            seenOnboarding ? const _LockedShell() : const OnboardingScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                color: AppConstants.primaryColor,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.psychology,
                size: 64,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              AppConstants.appName,
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Your Private AI Agent',
              style: TextStyle(fontSize: 16, color: Colors.grey[400]),
            ),
            const SizedBox(height: 48),
            const CircularProgressIndicator(),
          ],
        ),
      ),
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
