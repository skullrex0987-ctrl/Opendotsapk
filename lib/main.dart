import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import 'app.dart';

/// Background task dispatcher (required by WorkManager).
/// Must be a top-level function marked with @pragma('vm:entry-point').
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    switch (task) {
      case 'calendar_check':
        debugPrint('LocalMind: calendar check task running');
        return true;
      default:
        debugPrint('LocalMind: unknown task $task');
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

  // WorkManager can fail on some devices/emulators; never let it block startup.
  try {
    await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  } catch (e) {
    debugPrint('LocalMind: WorkManager init failed: $e');
  }

  runApp(const ProviderScope(child: LocalMindApp()));
}
