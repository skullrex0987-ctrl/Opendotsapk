/// Biometric / device-credential lock.
///
/// Deliberately a *gate*, not encryption: the database key still comes from the
/// keystore, so this raises the effort needed to read a device someone is
/// holding, and does not claim to protect against an attacker who can read
/// process memory.
///
/// Fails open by design. If the device has no biometrics enrolled, or the
/// platform refuses, the app opens rather than locking the user out of their
/// own notes.
library;

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../core/utils/log.dart';

class BiometricGate extends StatefulWidget {
  final Widget child;

  /// Whether the user turned the lock on. When false the gate is transparent.
  final bool enabled;

  const BiometricGate({
    super.key,
    required this.child,
    required this.enabled,
  });

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate>
    with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();

  bool _unlocked = false;
  bool _checking = false;
  String? _message;

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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-lock when the app goes to the background, but only after it is
    // unlocked — otherwise a permission dialog would immediately re-lock it.
    if (state == AppLifecycleState.paused && widget.enabled && _unlocked) {
      setState(() => _unlocked = false);
    }
    if (state == AppLifecycleState.resumed &&
        widget.enabled &&
        !_unlocked &&
        !_checking) {
      _authenticate();
    }
  }

  Future<void> _authenticate() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _message = null;
    });

    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;

      if (!supported || !canCheck) {
        // No biometrics available: do not trap the user outside their data.
        Log.w('biometrics unavailable; opening without a lock');
        if (mounted) {
          setState(() {
            _unlocked = true;
            _checking = false;
          });
        }
        return;
      }

      final ok = await _auth.authenticate(
        localizedReason: 'Unlock LocalMind',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          useErrorDialogs: true,
        ),
      );

      if (!mounted) return;
      setState(() {
        _unlocked = ok;
        _checking = false;
        _message = ok ? null : 'Authentication was cancelled.';
      });
    } catch (e) {
      Log.w('biometric auth failed: $e');
      if (!mounted) return;
      setState(() {
        _checking = false;
        _message = 'Could not use biometrics: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_unlocked) return widget.child;

    return Scaffold(
      body: Center(
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
              'LocalMind is locked',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _message ??
                    'Unlock to continue. Your data stays on this device.',
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
        ),
      ),
    );
  }
}
