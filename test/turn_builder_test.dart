/// Tests for conversation-history selection.
///
/// The bug these pin: the old code did `history.take(10)` on a chronological
/// list, so it sent the ten OLDEST messages and dropped everything recent. A
/// 40-message conversation therefore asked the model about the first ten turns
/// and nothing else. Every test below is written so that regression cannot
/// return unnoticed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/utils/turn_builder.dart';

void main() {
  group('estimateTokens', () {
    test('is pessimistic rather than optimistic', () {
      // 4 chars/token, rounded UP. Under-estimating would silently truncate.
      expect(estimateTokens('abcd'), 1);
      expect(estimateTokens('abcde'), 2);
      expect(estimateTokens(''), 0);
    });
  });

  group('buildRecentTurns', () {
    test('keeps the MOST RECENT turns, not the oldest', () {
      // 40 messages, "message 0" oldest through "message 39" newest.
      final history = [
        for (var i = 0; i < 40; i++)
          Turn(i.isEven ? 'user' : 'assistant', 'message $i'),
      ];

      final sel = buildRecentTurns(history: history, tokenBudget: 60);

      final text = sel.turns.map((t) => t.content).join('|');
      expect(text, contains('message 39'),
          reason: 'the newest message must survive');
      expect(text, isNot(contains('message 0')),
          reason: 'the oldest messages must be the ones dropped');
    });

    test('never exceeds the token budget', () {
      final history = [
        for (var i = 0; i < 40; i++) Turn('user', 'x' * 200),
      ];
      const budget = 200;

      final sel = buildRecentTurns(history: history, tokenBudget: budget);

      expect(sel.estimatedTokens, lessThanOrEqualTo(budget + 60),
          reason: 'only the always-kept question may exceed the budget');
    });

    test('always includes the system prompt', () {
      final history = [Turn('user', 'hello')];
      final sel = buildRecentTurns(
        history: history,
        tokenBudget: 100,
        systemPrompt: 'You are terse.',
      );

      expect(sel.turns.first.role, 'system');
      expect(sel.turns.first.content, 'You are terse.');
    });

    test('omits an empty system prompt rather than sending a blank turn', () {
      final sel = buildRecentTurns(
        history: [Turn('user', 'hi')],
        tokenBudget: 100,
        systemPrompt: '   ',
      );
      expect(sel.turns.any((t) => t.role == 'system'), isFalse);
    });

    test('keeps the final user turn even when it alone blows the budget', () {
      // A prompt with no question in it is useless, so the question wins.
      final history = [
        Turn('assistant', 'x' * 4000),
        Turn('user', 'the actual question'),
      ];

      final sel = buildRecentTurns(history: history, tokenBudget: 20);

      expect(sel.turns.last.content, 'the actual question');
      expect(sel.truncated, isTrue);
    });

    test('returns turns in chronological order', () {
      final history = [
        Turn('user', 'first'),
        Turn('assistant', 'second'),
        Turn('user', 'third'),
      ];

      final sel = buildRecentTurns(history: history, tokenBudget: 500);

      expect(sel.turns.map((t) => t.content).toList(),
          ['first', 'second', 'third']);
    });

    test('a turn appears exactly once', () {
      // The old path added the user message to the provider and then appended
      // it to the prompt again, so the model saw the question twice.
      final history = [Turn('user', 'only once')];

      final sel = buildRecentTurns(history: history, tokenBudget: 500);

      expect(sel.turns.where((t) => t.content == 'only once').length, 1);
    });

    test('handles an empty history', () {
      final sel = buildRecentTurns(history: const [], tokenBudget: 500);
      expect(sel.turns, isEmpty);
      expect(sel.estimatedTokens, 0);
      expect(sel.truncated, isFalse);
    });

    test('reserves room for the response', () {
      final history = [for (var i = 0; i < 20; i++) Turn('user', 'y' * 100)];

      final generous = buildRecentTurns(history: history, tokenBudget: 1000);
      final reserved = buildRecentTurns(
        history: history,
        tokenBudget: 1000,
        reserveForResponse: 500,
      );

      expect(reserved.turns.length, lessThan(generous.turns.length),
          reason: 'reserving space must evict older turns');
      expect(reserved.estimatedTokens,
          lessThanOrEqualTo(generous.estimatedTokens));
    });

    test('reports truncation when history is dropped', () {
      final history = [for (var i = 0; i < 30; i++) Turn('user', 'z' * 300)];

      final sel = buildRecentTurns(history: history, tokenBudget: 200);

      expect(sel.truncated, isTrue);
      expect(sel.turns.length, lessThan(history.length));
    });

    test('does not claim truncation when everything fits', () {
      final history = [Turn('user', 'short')];
      final sel = buildRecentTurns(history: history, tokenBudget: 500);
      expect(sel.truncated, isFalse);
    });

    test('drops old turns but keeps a contiguous recent window', () {
      final history = [
        for (var i = 0; i < 20; i++) Turn('user', 'm$i'),
      ];

      final sel = buildRecentTurns(history: history, tokenBudget: 60);
      final contents = sel.turns.map((t) => t.content).toList();

      // Whatever survives must be the tail of the conversation, in order.
      final expectedTail = history
          .map((t) => t.content)
          .toList()
          .sublist(history.length - contents.length);
      expect(contents, expectedTail);
    });
  });
}
