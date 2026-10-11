/// Main screen with bottom navigation.
///
/// Five destinations. Chat and the model list are separate because picking a
/// model is a settings-shaped task, while Memory and Activity are read-mostly.
import 'package:flutter/material.dart';

import '../../core/theme/motion.dart';
import 'chat_screen.dart';
import 'memory_screen.dart';
import 'activity_screen.dart';
import 'settings_screen.dart';
import 'tools_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  // The tab bodies are held in a const list and never rebuilt, which is what
  // preserves each tab's state: rebuilding Chat would drop a half-typed
  // message, and rebuilding Settings would drop its scroll position.
  final List<Widget> _screens = const [
    ChatScreen(),
    MemoryScreen(),
    ToolsScreen(),
    ActivityScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < _screens.length; i++)
            _TabSlot(
              // Keyed by index so each slot's animation state survives the
              // rebuild that a tab switch triggers. Without this the incoming
              // tab would restart its slide on every subsequent tap.
              key: ValueKey<int>(i),
              selected: i == _currentIndex,
              child: _screens[i],
            ),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant
                  .withValues(alpha: 0.5),
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) =>
              setState(() => _currentIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              selectedIcon: Icon(Icons.chat_bubble),
              label: 'Chat',
            ),
            NavigationDestination(
              icon: Icon(Icons.psychology_outlined),
              selectedIcon: Icon(Icons.psychology),
              label: 'Memory',
            ),
            NavigationDestination(
              icon: Icon(Icons.handyman_outlined),
              selectedIcon: Icon(Icons.handyman),
              label: 'Tools',
            ),
            NavigationDestination(
              icon: Icon(Icons.history_outlined),
              selectedIcon: Icon(Icons.history),
              label: 'Activity',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

/// One tab's slot in the shell.
///
/// Every tab stays mounted — that is the whole point, and it is why switching
/// away from Chat and back does not lose a half-typed message. What animates is
/// only the opacity and offset, so the old tab fades and slides out under the
/// new one instead of both snapping into place at once.
///
/// [AnimatedOpacity] rather than a plain [Opacity] specifically because it
/// drops the subtree's paint entirely at zero opacity: with an [IndexedStack]
/// only the visible child was ever painted, and five screens painting
/// simultaneously on a mid-range phone is a real regression.
class _TabSlot extends StatelessWidget {
  const _TabSlot({super.key, required this.selected, required this.child});

  final bool selected;
  final Widget child;

  /// How far a tab travels as it changes. Short on purpose — this is a
  /// cross-fade with a hint of direction, not a carousel.
  static const double _slide = 12;

  static const Duration _duration = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // An invisible tab must not be tappable, or a stray tap lands on
      // whatever is under it.
      ignoring: !selected,
      child: ExcludeSemantics(
        // Matches IndexedStack, which reported only the visible child to
        // screen readers; without this a TalkBack user would hear all five
        // tabs stacked on top of each other.
        excluding: !selected,
        child: AnimatedOpacity(
          opacity: selected ? 1 : 0,
          duration: _duration,
          curve: AppMotion.standard,
          child: TweenAnimationBuilder<Offset>(
            // TweenAnimationBuilder animates from wherever the previous tween
            // ended to the new `end`, so deselecting slides *down* out and
            // selecting slides *up* in without either direction being
            // special-cased. `tween` must be a real Tween: handing it a bare
            // Offset does not compile.
            tween: Tween<Offset>(
              begin: Offset.zero,
              end: Offset(0, selected ? 0 : _slide),
            ),
            duration: _duration,
            curve: AppMotion.standard,
            builder: (context, offset, child) =>
                Transform.translate(offset: offset, child: child),
            child: child,
          ),
        ),
      ),
    );
  }
}
