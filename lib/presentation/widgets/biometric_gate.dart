/// Biometric / device-credential lock.
///
/// Deliberately a *gate*, not encryption: the database key still comes from the
/// keystore, so this raises the effort needed to read a device someone is
/// holding, and does not claim to protect against an attacker who can read
/// process memory.
///
/// Fails closed. The lock is only dropped after the platform has actually
/// authenticated the user. When the platform cannot authenticate at all — no
/// enrolled biometric *and* no device PIN/pattern/password — the app stays
/// shut and explains the two ways out rather than opening silently. An earlier
/// revision keyed on `canCheckBiometrics`, which reports false on any device
/// without an enrolled fingerprint; that opened the lock for a device that a
/// system PIN would have unlocked, i.e. it failed open on a security control.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/utils/log.dart';

/// Dart side of the `com.localmind.localmind/secure_screen` platform channel.
///
/// Sets `FLAG_SECURE` (and, on API 33+, `setRecentsScreenshotEnabled(false)`)
/// so the OS keeps note contents out of screenshots and the recents thumbnail.
/// Deliberately forgiving: the channel is absent in unit tests and on any
/// non-Android host, and a cosmetic privacy tweak is not worth crashing over,
/// so every failure is logged and swallowed.
class SecureScreen {
  SecureScreen._();

  static const MethodChannel _channel =
      MethodChannel('com.localmind.localmind/secure_screen');

  /// Block screenshots and the recents thumbnail.
  static Future<void> enable() async {
    try {
      await _channel.invokeMethod<void>('enableSecure');
    } catch (e) {
      Log.w('could not enable secure window: $e');
    }
  }

  /// Allow screenshots and the recents thumbnail again (lock turned off).
  static Future<void> disable() async {
    try {
      await _channel.invokeMethod<void>('disableSecure');
    } catch (e) {
      Log.w('could not clear secure window: $e');
    }
  }

  /// Open the Android security settings so the user can set a screen lock.
  static Future<void> openSecuritySettings() async {
    try {
      await _channel.invokeMethod<void>('openSecuritySettings');
    } catch (e) {
      Log.w('could not open Android security settings: $e');
    }
  }
}

class BiometricGate extends StatefulWidget {
  final Widget child;

  /// Whether the user turned the lock on. When false the gate is transparent.
  final bool enabled;

  /// Called when the user chooses to drop the lock from the fail-closed
  /// screen (a device with no screen lock). The owner writes the setting;
  /// the gate then opens on the next rebuild.
  final Future<void> Function()? onDisableLock;

  const BiometricGate({
    super.key,
    required this.child,
    required this.enabled,
    this.onDisableLock,
  });

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate>
    with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();

  bool _unlocked = false;
  bool _checking = false;

  /// Fail-closed state: the lock is on but this device has no credential the
  /// platform can ask for. Shown instead of the normal Unlock screen.
  bool _blocked = false;

  String? _message;

  /// Timestamp guard against spurious re-locks.
  ///
  /// The document picker, runtime permission sheets and the biometric prompt
  /// are all separate activities drawn over ours, so each hands the app a
  /// pause/resume pair. Without a guard that pair looks identical to the user
  /// actually backgrounding the app, and the lock re-arms the moment they come
  /// back from picking a file. We open a short window before we start any such
  /// flow and ignore lifecycle events that land inside it.
  DateTime? _suppressLockUntil;

  /// Cross-widget version of the same guard, for call sites (the chat screen's
  /// picker, permission requests) that leave the app on purpose but do not own
  /// the gate. A static setter keeps that call to one line at the call site.
  static DateTime? _globalSuppressUntil;

  /// Ignore pause/resume for [window] so the next external activity does not
  /// re-arm the lock. Safe to call when no gate is mounted.
  static void suppressReLock([
    Duration window = const Duration(seconds: 3),
  ]) {
    _globalSuppressUntil = DateTime.now().add(window);
  }

  bool get _suppressed {
    final now = DateTime.now();
    final local = _suppressLockUntil;
    if (local != null && now.isBefore(local)) return true;
    final global = _globalSuppressUntil;
    if (global != null && now.isBefore(global)) return true;
    return false;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!widget.enabled) {
      _unlocked = true;
    } else {
      _authenticate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BiometricGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled == oldWidget.enabled) return;

    if (!widget.enabled) {
      // Lock switched off while we sat here: drop it immediately.
      _suppressLockUntil = null;
      setState(() {
        _unlocked = true;
        _blocked = false;
        _message = null;
      });
    } else {
      // Lock switched on: re-arm and ask for a credential.
      setState(() {
        _unlocked = false;
        _blocked = false;
      });
      _authenticate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.enabled) return;

    // A pause inside the suppression window belongs to a flow we started on
    // purpose, so it must not re-arm the lock.
    if (state == AppLifecycleState.paused && _unlocked && !_suppressed) {
      setState(() => _unlocked = false);
      return;
    }

    // While _blocked we still re-check on resume: the user may have just come
    // back from Android settings having set the screen lock the app asked for.
    // _authenticate re-runs the isDeviceSupported probe and re-blocks if not.
    if (state == AppLifecycleState.resumed &&
        !_unlocked &&
        !_checking &&
        !_suppressed) {
      _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_checking) return;

    // The sheet is drawn over our activity, so it can hand us its own
    // pause/resume pair. Ignore lifecycle for a moment so it does not re-arm
    // the lock it just satisfied.
    _suppressLockUntil = DateTime.now().add(const Duration(seconds: 3));

    setState(() {
      _checking = true;
      _message = null;
    });

    try {
      // `isDeviceSupported` means the platform *can* authenticate — a system
      // PIN/pattern/password counts, not just enrolled fingerprints. This is
      // the correct gate; `canCheckBiometrics` only means a fingerprint is
      // enrolled and is false on a PIN-only device.
      final supported = await _auth.isDeviceSupported();

      if (!supported) {
        // No credential of any kind. Fail closed: stay locked and explain.
        Log.w('no usable device credential; keeping the lock engaged');
        if (!mounted) return;
        setState(() {
          _checking = false;
          _blocked = true;
        });
        return;
      }

      final ok = await _auth.authenticate(
        localizedReason: 'Unlock LocalMind',
        // local_auth 3.x flattened these: `options:`/`stickyAuth` are gone.
        // biometricOnly: false lets a PIN/pattern/password stand in — which is
        // the whole point of the isDeviceSupported gate above.
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );

      // Re-arm the guard now the sheet is gone: some devices deliver its pause
      // after authenticate() has already returned.
      _suppressLockUntil = DateTime.now().add(const Duration(seconds: 2));

      if (!mounted) return;
      setState(() {
        _unlocked = ok;
        _blocked = false;
        _checking = false;
        _message = ok ? null : 'Authentication was cancelled. Try again.';
      });
    } catch (e) {
      Log.w('device-credential auth failed: $e');
      if (!mounted) return;
      setState(() {
        _checking = false;
        _message = 'Could not authenticate: $e';
      });
    }
  }

  /// Explicitly drop the lock from the fail-closed screen and open.
  Future<void> _disableLockAndOpen() async {
    _suppressLockUntil = DateTime.now().add(const Duration(seconds: 5));
    setState(() {
      _unlocked = true;
      _blocked = false;
    });
    try {
      await widget.onDisableLock?.call();
    } catch (e) {
      Log.w('could not turn the lock off: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;

    return Scaffold(
      body: Center(
        child: _blocked ? _buildNoCredential() : _buildLocked(),
      ),
    );
  }

  Widget _buildLocked() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.lock_outline,
          size: 56,
          color: Colors.grey[500],
        ),
        const SizedBox(height: 16),
        const Text(
          'LocalMind is locked',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            _message ?? 'Unlock to continue. Your data stays on this device.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _checking ? null : _authenticate,
          icon: _checking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.fingerprint),
          label: Text(_checking ? 'Waiting…' : 'Unlock'),
        ),
      ],
    );
  }

  Widget _buildNoCredential() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            size: 56,
            color: Colors.grey[500],
          ),
          const SizedBox(height: 16),
          const Text(
            'LocalMind can’t lock',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'This device has no screen lock — no PIN, pattern, password or '
            'biometrics. LocalMind keeps your notes shut rather than opening '
            'them without one.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: SecureScreen.openSecuritySettings,
            icon: const Icon(Icons.settings),
            label: const Text('Set a screen lock'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _disableLockAndOpen,
            child: const Text('Turn off the lock and open'),
          ),
        ],
      ),
    );
  }
}
