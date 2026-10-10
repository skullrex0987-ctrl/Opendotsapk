import 'package:flutter/material.dart';
import 'presentation/screens/main_screen.dart';
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
        cardTheme: CardTheme(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
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

/// Brief splash screen, then hands off to the main shell.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const MainScreen()),
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
              child: const Icon(Icons.psychology, size: 64, color: Colors.white),
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
