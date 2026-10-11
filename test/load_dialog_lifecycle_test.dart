/// The progress dialog opened by "Load" must never outlive its own guards.
///
/// Regression guard for a freeze reported from a real device: tapping Load with
/// a mismatched vision/LLM pairing showed a `barrierDismissible: false`
/// spinner, and the guard that refused the load `return`ed with that dialog
/// still on screen. The user could not tap it away and the load never started,
/// so the app looked busy while doing nothing — "I tap Load many times and it
/// never loads".
///
/// This is asserted against the source rather than by pumping the screen: the
/// behaviour depends on *statement order* across an `await` boundary inside a
/// private method of a large screen widget, and the screen pulls in the native
/// llama runtime, which cannot be instantiated in a unit test.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('_loadSelectedModels dialog lifecycle', () {
    late String source;

    setUpAll(() {
      final file = File('lib/presentation/screens/chat_screen.dart');
      expect(file.existsSync(), isTrue, reason: 'chat_screen.dart not found');
      source = file.readAsStringSync();
    });

    /// The body of `_loadSelectedModels`, from its signature to the next method.
    String body() {
      final start = source.indexOf('Future<void> _loadSelectedModels');
      expect(start, greaterThan(-1), reason: '_loadSelectedModels not found');
      final end = source.indexOf('Future<void> _loadModelFromStorage', start);
      expect(end, greaterThan(start), reason: 'could not delimit the method');
      return source.substring(start, end);
    }

    /// Index of the first occurrence of [needle] in the method body.
    int at(String needle) {
      final i = body().indexOf(needle);
      expect(i, greaterThan(-1), reason: 'not found in method: $needle');
      return i;
    }

    test('every refusal happens before the dialog opens', () {
      final dialog = at('showDialog(');
      final archGuard = at('chatArch != visionArch');
      expect(
        archGuard,
        lessThan(dialog),
        reason:
            'the architecture guard must refuse before showDialog, otherwise a '
            'mismatched pairing returns with a non-dismissible spinner up',
      );
    });

    test('the dialog is not opened before the install check', () {
      expect(
        at('isInstalled(chat)'),
        lessThan(at('showDialog(')),
        reason: 'an undownloaded model must be reported before the spinner',
      );
    });

    test('no bare return sits between the dialog opening and the try block', () {
      final region = body().substring(at('showDialog('), at('try {'));
      expect(
        RegExp(r'^\s*return;', multiLine: true).hasMatch(region),
        isFalse,
        reason:
            'a return after showDialog strands the spinner: any refusal there '
            'leaves a dialog the user cannot dismiss',
      );
    });

    test('the spinner is closed through a navigator captured up front', () {
      // Reaching for `Navigator.of(context)` after an await means an unmounted
      // context skips the pop and strands the spinner. The navigator has to be
      // captured before the dialog opens.
      expect(
        at('final navigator = Navigator.of(context);'),
        lessThan(at('showDialog(')),
        reason: 'the navigator must be captured before the dialog opens',
      );
      expect(
        body().contains('if (navigator.canPop()) navigator.pop();'),
        isTrue,
        reason:
            'the dialog must be closed via the captured navigator, and the pop '
            'guarded so a second pop cannot throw',
      );
      expect(
        body().contains('Navigator.of(context).pop()'),
        isFalse,
        reason:
            'a late Navigator.of(context).pop() is skipped when the context '
            'unmounts mid-load, which strands the spinner',
      );
    });

    test('the loading path is inside a try, so a throw still closes the dialog', () {
      final region = body().substring(at('showDialog('));
      expect(region.contains('} catch'), isTrue);
      // And the pop must sit after the catch, so a thrown error cannot skip it.
      expect(
        at('navigator.canPop()'),
        greaterThan(at('} catch')),
        reason: 'the spinner must be closed after the catch block',
      );
    });
  });

  group('every non-dismissible spinner has an exception-safe close', () {
    /// The same freeze class as above, elsewhere: a spinner that is only
    /// closed on the success path. If the awaited work throws, the spinner
    /// stays and the error surfaces *behind* it.
    late Map<String, String> sources;

    /// Strips line comments so a pattern quoted inside an explanatory comment
    /// is not mistaken for live code.
    String code(String src) => src
        .split('\n')
        .map((l) {
          final i = l.indexOf('//');
          return i == -1 ? l : l.substring(0, i);
        })
        .join('\n');

    setUpAll(() {
      sources = {
        'chat_screen.dart': File('lib/presentation/screens/chat_screen.dart')
            .readAsStringSync(),
        'performance_screen.dart': File(
          'lib/presentation/screens/performance_screen.dart',
        ).readAsStringSync(),
      };
    });

    test('no spinner is closed only via a post-await Navigator.of(context).pop()', () {
      // A late `Navigator.of(context).pop()` is skipped when the context
      // unmounts during the await, and never runs at all when the awaited work
      // throws. Both strand the spinner.
      final offenders = <String>[];
      for (final entry in sources.entries) {
        if (RegExp(r'Navigator\.of\(\w+\)\.pop\(\)')
            .hasMatch(code(entry.value))) {
          offenders.add(entry.key);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'these still close a spinner through a late Navigator.of(...).pop() '
            '— skipped when the context unmounts or the load throws: $offenders',
      );
    });

    test('each showDialog is paired with a captured-navigator close', () {
      for (final entry in sources.entries) {
        final src = code(entry.value);
        final dialogs = RegExp(r'showDialog\(').allMatches(src).length;
        expect(dialogs, greaterThan(0));
        // Every spinner close goes through a navigator captured beforehand.
        final lateCloses = RegExp(r'Navigator\.of\(\w+\)\.pop\(\)')
            .allMatches(src)
            .length;
        final capturedCloses = RegExp(
          r'(?:navigator|nav)\.canPop\(\)\)\s*(?:navigator|nav)\.pop\(\)',
        ).allMatches(src).length;
        expect(
          lateCloses,
          0,
          reason:
              '${entry.key} has $lateCloses close(s) that can be skipped; '
              'use a navigator captured before the await',
        );
        expect(
          capturedCloses,
          greaterThanOrEqualTo(1),
          reason: '${entry.key} captures no navigator for its spinner',
        );
      }
    });
  });
}
