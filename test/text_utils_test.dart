/// Tests for the text utilities that back retrieval.
///
/// These matter more than they look: chunking decides what a small on-device
/// model ever gets to see, and BM25 scoring is only as good as its tokenizer.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/utils/text_utils.dart';

void main() {
  group('tokenize', () {
    test('lowercases and splits on punctuation', () {
      expect(TextUtils.tokenize('Hello, World!'), ['hello', 'world']);
    });

    test('keeps intra-word apostrophes as one token', () {
      expect(TextUtils.tokenize("don't stop"), ["don't", 'stop']);
    });

    test('trims leading and trailing apostrophes', () {
      expect(TextUtils.tokenize("'quoted'"), ['quoted']);
    });

    test('splits hyphenated technical terms', () {
      expect(TextUtils.tokenize('gpt-4 turbo'), ['gpt', '4', 'turbo']);
    });

    test('keeps digits attached to words', () {
      expect(TextUtils.tokenize('llama3 runs'), ['llama3', 'runs']);
    });

    test('returns empty for punctuation-only input', () {
      expect(TextUtils.tokenize('!!! ??? ...'), isEmpty);
    });

    test('handles empty input', () {
      expect(TextUtils.tokenize(''), isEmpty);
    });

    test('handles accented latin text', () {
      expect(TextUtils.tokenize('Café déjà'), ['café', 'déjà']);
    });
  });

  group('termFrequencies', () {
    test('counts repeats', () {
      final tf = TextUtils.termFrequencies(['a', 'b', 'a', 'a']);
      expect(tf['a'], 3);
      expect(tf['b'], 1);
    });
  });

  group('cosine', () {
    test('identical vectors score 1', () {
      expect(TextUtils.cosine([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]),
          closeTo(1.0, 1e-9));
    });

    test('orthogonal vectors score 0', () {
      expect(TextUtils.cosine([1.0, 0.0], [0.0, 1.0]), closeTo(0.0, 1e-9));
    });

    test('opposite vectors score -1', () {
      expect(TextUtils.cosine([1.0, 0.0], [-1.0, 0.0]), closeTo(-1.0, 1e-9));
    });

    test('is magnitude independent', () {
      expect(TextUtils.cosine([1.0, 1.0], [50.0, 50.0]), closeTo(1.0, 1e-9));
    });

    test('returns 0 for an empty vector rather than NaN', () {
      expect(TextUtils.cosine([], [1.0]), 0);
    });

    test('returns 0 when one vector is all zeros', () {
      expect(TextUtils.cosine([0.0, 0.0], [1.0, 1.0]), 0);
    });

    test('handles mismatched lengths using the shorter', () {
      expect(TextUtils.cosine([1.0, 0.0], [1.0, 0.0, 9.0]),
          closeTo(1.0, 1e-9));
    });
  });

  group('chunk', () {
    test('short text is a single chunk', () {
      expect(TextUtils.chunk('hello world'), ['hello world']);
    });

    test('empty text yields no chunks', () {
      expect(TextUtils.chunk(''), isEmpty);
      expect(TextUtils.chunk('   \n\n  '), isEmpty);
    });

    test('long text splits into several chunks', () {
      final para = '${'word ' * 200}\n\n';
      final chunks = TextUtils.chunk(para * 5, targetChars: 500);
      expect(chunks.length, greaterThan(1));
    });

    test('every chunk stays within the target plus overlap tolerance', () {
      final text = List.generate(40, (i) => 'Sentence number $i is here. ')
          .join();
      final chunks = TextUtils.chunk(text, targetChars: 300, overlapChars: 50);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(320));
      }
    });

    test('consecutive chunks overlap so boundary facts are not lost', () {
      final text = List.generate(
        60,
        (i) => 'Paragraph $i contains distinctive token$i. ',
      ).join();
      final chunks =
          TextUtils.chunk(text, targetChars: 400, overlapChars: 100);
      expect(chunks.length, greaterThan(1));

      // The tail of chunk N should reappear at the head of chunk N+1.
      final tail = chunks[0].substring(chunks[0].length - 40);
      final head = chunks[1].length >= 40
          ? chunks[1].substring(0, chunks[1].length)
          : chunks[1];
      final overlapWord = tail.trim().split(' ').last;
      expect(head.contains(overlapWord), isTrue);
    });

    test('splits on paragraph boundaries when possible', () {
      final chunks = TextUtils.chunk(
        '${'a' * 200}\n\n${'b' * 200}',
        targetChars: 250,
        overlapChars: 0,
      );
      expect(chunks.length, 2);
      expect(chunks[0].contains('a'), isTrue);
      expect(chunks[1].contains('b'), isTrue);
    });

    test('a single gigantic sentence is hard-windowed, not dropped', () {
      final monster = 'x' * 5000;
      final chunks = TextUtils.chunk(monster, targetChars: 1000);
      expect(chunks, isNotEmpty);
      expect(chunks.join().length, greaterThanOrEqualTo(5000));
    });
  });

  group('ellipsize', () {
    test('leaves short strings alone', () {
      expect(TextUtils.ellipsize('short', 20), 'short');
    });

    test('cuts on a word boundary and adds an ellipsis', () {
      final out = TextUtils.ellipsize('the quick brown fox jumps', 20);
      expect(out.endsWith('…'), isTrue);
      expect(out.length, lessThanOrEqualTo(21));
    });
  });

  group('estimateTokens', () {
    test('is roughly characters over four', () {
      expect(TextUtils.estimateTokens('a' * 400), 100);
    });

    test('zero for empty', () {
      expect(TextUtils.estimateTokens(''), 0);
    });
  });
}
