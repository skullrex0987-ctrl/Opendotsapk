/// Regression tests for the LLM wire format.
///
/// This file exists because of a specific, expensive bug. `NativeLlama`'s
/// `generateResponse` reads `m['text']!` — and the obvious spelling for anyone
/// who has used an OpenAI-shaped API is `content`. Passing `content` makes the
/// null-assertion throw *inside the stream controller's onListen callback*:
///
///   * the exception never reaches the caller's `await for`, because it is
///     raised while the stream is being set up rather than emitted on it;
///   * `startGeneration` is never invoked, and the controller is never closed.
///
/// The app therefore sat on "Thinking…" forever with an empty log. It compiled
/// cleanly, every other test passed, and it only appeared on a real device.
///
/// These tests are cheap and they pin the contract.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/llm_service.dart';

void main() {
  group('LLM wire format', () {
    test("every message carries a 'text' key", () {
      final wire = LlmService.wire('hello');

      expect(wire, hasLength(1));
      expect(wire.single['text'], 'hello');
      expect(wire.single['role'], 'user');
    });

    test("no message uses 'content' as the payload key", () {
      // The plugin reads `text`; `content` is the trap. If this ever fails,
      // the chat screen hangs with no error on a real device.
      final wire = LlmService.wire(
        'hello',
        systemPrompt: 'be brief',
        history: [
          {'role': 'user', 'text': 'earlier question'},
          {'role': 'assistant', 'text': 'earlier answer'},
        ],
      );

      for (final m in wire) {
        expect(m.containsKey('text'), isTrue,
            reason: 'message $m has no text key');
        expect(m.containsKey('content'), isFalse,
            reason: 'message $m uses content, which the plugin cannot read');
        expect(m['text'], isNotNull);
      }
    });

    test('system prompt, history and prompt are ordered correctly', () {
      final wire = LlmService.wire(
        'current',
        systemPrompt: 'sys',
        history: [
          {'role': 'user', 'text': 'q1'},
          {'role': 'assistant', 'text': 'a1'},
        ],
      );

      expect(wire.map((m) => m['role']).toList(),
          ['system', 'user', 'assistant', 'user']);
      expect(wire.map((m) => m['text']).toList(),
          ['sys', 'q1', 'a1', 'current']);
    });

    test('history entries that use content are migrated to text', () {
      // Callers elsewhere in the app build history from ChatMessage, which used
      // `content`. Those must be normalised rather than crashing.
      final wire = LlmService.wire(
        'next',
        history: [
          {'role': 'user', 'content': 'legacy question'},
        ],
      );

      expect(wire.first['text'], 'legacy question');
      expect(wire.first.containsKey('content'), isFalse);
    });

    test('empty history entries are dropped', () {
      final wire = LlmService.wire(
        'next',
        history: [
          {'role': 'user', 'text': ''},
          {'role': 'assistant', 'text': 'kept'},
        ],
      );

      expect(wire.map((m) => m['text']).toList(), ['kept', 'next']);
    });

    test('an empty system prompt is omitted rather than sent blank', () {
      final wire = LlmService.wire('hi', systemPrompt: '');
      expect(wire, hasLength(1));
      expect(wire.single['role'], 'user');
    });

    test('the prompt is always last, so the model answers it', () {
      final wire = LlmService.wire(
        'FINAL',
        systemPrompt: 'sys',
        history: [
          {'role': 'user', 'text': 'a'},
          {'role': 'assistant', 'text': 'b'},
        ],
      );

      expect(wire.last['text'], 'FINAL');
      expect(wire.last['role'], 'user');
    });
  });
}
