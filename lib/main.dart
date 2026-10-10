import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'core/security/crypto_box.dart';
import 'core/utils/log.dart';
import 'data/services/router_service.dart';
import 'data/services/secure_store.dart';

/// Background task dispatcher (required by WorkManager).
/// Must be a top-level function marked with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    switch (task) {
      case 'calendar_check':
        Log.d('calendar check task running');
        return true;
      default:
        Log.d('unknown task $task');
        return false;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait only.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Transparent status bar, light icons.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // ---------------------------------------------------------------------------
  // Encryption key.
  //
  // Loaded before the first database read, because messages and memories are
  // stored encrypted. If the keystore is unavailable the app deliberately
  // continues in plaintext rather than refusing to start — losing access to the
  // user's own notes would be worse than the protection it buys.
  // ---------------------------------------------------------------------------
  try {
    final key = await SecureStore.instance.databaseKey();
    if (key != null) {
      CryptoBox.instance.installKey(key);
      Log.i('at-rest encryption active');
    } else {
      CryptoBox.instance.disable();
      Log.w('keystore unavailable — running without at-rest encryption');
    }
  } catch (e) {
    CryptoBox.instance.disable();
    Log.w('encryption setup failed, continuing in plaintext: $e');
  }

  // Connectivity matters for the router: offline must force the local model.
  // A DNS probe is used rather than an HTTP request so it costs no data and
  // reveals no request metadata.
  try {
    await RouterService.instance.probeConnectivity();
  } catch (_) {
    // Defaults to online; the router re-checks later.
  }

  // WorkManager can fail on some devices/emulators; never let it block startup.
  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  } catch (e) {
    Log.w('WorkManager init failed: $e');
  }

  runApp(const ProviderScope(child: LocalMindApp()));
}
