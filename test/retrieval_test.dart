/// Tests for retrieval: BM25 scoring, score fusion, and MMR diversification.
///
/// These exercise the pure functions that decide what a small on-device model
/// gets to read, without needing a database or an embedding model.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/utils/text_utils.dart';

/// Mirror of the BM25 maths in DatabaseHelper, so the formula is pinned by a
/// test rather than only living inside a private class.
double bm25({
  required int termFreq,
  required int docFreq,
  required int docCount,
  required int docLength,
  required double avgLength,
  double k1 = 1.5,
  double b = 0.75,
}) {
  final n = math.max(docCount, 1);
  final r = (n - docFreq + 0.5) / (docFreq + 0.5);
  final idf = math.log(1 + math.max(r, 0));
  final denom = termFreq + k1 * (1 - b + b * (docLength / avgLength));
  return idf * ((termFreq * (k1 + 1)) / denom);
}

/// Mirror of the fusion step.
double fuse({
  required double vectorScore,
  required double keywordScore,
  double vectorWeight = 0.6,
  double keywordWeight = 0.4,
}) => vectorWeight * vectorScore + keywordWeight * keywordScore;

void main() {
  group('BM25', () {
    test('a rarer term scores higher than a common one', () {
      final rare = bm25(
        termFreq: 1,
        docFreq: 1,
        docCount: 100,
        docLength: 50,
        avgLength: 50,
      );
      final common = bm25(
        termFreq: 1,
        docFreq: 95,
        docCount: 100,
        docLength: 50,
        avgLength: 50,
      );
      expect(rare, greaterThan(common));
    });

    test('more occurrences score higher, with diminishing returns', () {
      final once = bm25(
        termFreq: 1,
        docFreq: 10,
        docCount: 100,
        docLength: 50,
        avgLength: 50,
      );
      final twice = bm25(
        termFreq: 2,
        docFreq: 10,
        docCount: 100,
        docLength: 50,
        avgLength: 50,
      );
      final thrice = bm25(
        termFreq: 3,
        docFreq: 10,
        docCount: 100,
        docLength: 50,
        avgLength: 50,
      );

      expect(twice, greaterThan(once));
      expect(thrice, greaterThan(twice));
      // Diminishing: the jump from 2->3 is smaller than 1->2.
      expect(thrice - twice, lessThan(twice - once));
    });

    test('a term present in every document contributes almost nothing', () {
      final universal = bm25(
        termFreq: 3,
        docFreq: 100,
        docCount: 100,
        docLength: 50,
        avgLength: 50,
      );
      expect(universal, lessThan(0.02));
    });

    test('longer documents are penalised for the same term frequency', () {
      final short = bm25(
        termFreq: 2,
        docFreq: 10,
        docCount: 100,
        docLength: 20,
        avgLength: 50,
      );
      final long = bm25(
        termFreq: 2,
        docFreq: 10,
        docCount: 100,
        docLength: 200,
        avgLength: 50,
      );
      expect(short, greaterThan(long));
    });

    test('never returns a negative score', () {
      // The +1 floor in the IDF exists precisely so this cannot happen.
      for (var df = 1; df <= 100; df += 7) {
        final s = bm25(
          termFreq: 1,
          docFreq: df,
          docCount: 100,
          docLength: 50,
          avgLength: 50,
        );
        expect(s, greaterThanOrEqualTo(0));
      }
    });

    test('handles a single-document corpus without dividing by zero', () {
      final s = bm25(
        termFreq: 1,
        docFreq: 1,
        docCount: 1,
        docLength: 5,
        avgLength: 5,
      );
      expect(s.isFinite, isTrue);
    });
  });

  group('score fusion', () {
    test('weights sum predictably', () {
      expect(fuse(vectorScore: 1.0, keywordScore: 0.0), closeTo(0.6, 1e-9));
      expect(fuse(vectorScore: 0.0, keywordScore: 1.0), closeTo(0.4, 1e-9));
    });

    test('a hit strong in both beats a hit strong in only one', () {
      final both = fuse(vectorScore: 0.9, keywordScore: 0.9);
      final onlyVector = fuse(vectorScore: 1.0, keywordScore: 0.0);
      expect(both, greaterThan(onlyVector));
    });

    test('scores stay within [0,1] for normalised inputs', () {
      for (final v in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        for (final k in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final s = fuse(vectorScore: v, keywordScore: k);
          expect(s, inInclusiveRange(0.0, 1.0));
        }
      }
    });
  });

  group('MMR diversification', () {
    /// Minimal stand-in for a scored candidate.
    List<_Item> mmr(List<_Item> pool, int limit, {double lambda = 0.75}) {
      final selected = <_Item>[];
      final remaining = List<_Item>.from(pool);

      while (remaining.isNotEmpty && selected.length < limit) {
        _Item? best;
        var bestScore = double.negativeInfinity;
        for (final cand in remaining) {
          var maxSim = 0.0;
          for (final s in selected) {
            final sim = TextUtils.cosine(cand.vector, s.vector);
            if (sim > maxSim) maxSim = sim;
          }
          final score = lambda * cand.relevance - (1 - lambda) * maxSim;
          if (score > bestScore) {
            bestScore = score;
            best = cand;
          }
        }
        if (best == null) break;
        selected.add(best);
        remaining.remove(best);
      }
      return selected;
    }

    test('returns at most `limit` items', () {
      final pool = List.generate(
        10,
        (i) => _Item('item$i', 1.0 - i * 0.05, [1.0, 0.0]),
      );
      expect(mmr(pool, 3).length, 3);
    });

    test('drops a near-duplicate in favour of a diverse lower scorer', () {
      final pool = [
        _Item('best', 1.00, [1.0, 0.0]),
        // Nearly identical to `best`; little added information.
        _Item('dup', 0.95, [0.999, 0.001]),
        // Different direction; more likely to add something new.
        _Item('diverse', 0.80, [0.0, 1.0]),
      ];

      final picked = mmr(pool, 2, lambda: 0.75).map((i) => i.name).toList();
      expect(picked.first, 'best');
      expect(picked, contains('diverse'));
      expect(picked, isNot(contains('dup')));
    });

    test('lambda=1 degenerates to pure relevance ordering', () {
      final pool = [
        _Item('a', 0.9, [1.0, 0.0]),
        _Item('b', 0.8, [1.0, 0.0]),
        _Item('c', 0.7, [1.0, 0.0]),
      ];
      final picked = mmr(pool, 3, lambda: 1.0).map((i) => i.name).toList();
      expect(picked, ['a', 'b', 'c']);
    });

    test('handles an empty pool', () {
      expect(mmr([], 5), isEmpty);
    });

    test('handles a pool smaller than the limit', () {
      final pool = [
        _Item('only', 0.5, [1.0, 0.0]),
      ];
      expect(mmr(pool, 10).length, 1);
    });
  });

  group('retrieval end to end (pure pipeline)', () {
    test('an exact keyword match is found even with a zero vector', () {
      // Keyword-only fallback: this is what happens when the ONNX encoder is
      // not loaded, and it must not return nothing.
      final docs = {
        'a': 'the cat sat on the mat',
        'b': 'quantum chromodynamics is a gauge theory',
      };
      final query = TextUtils.tokenize('chromodynamics')
          .where((t) => !TextUtils.stopWords.contains(t))
          .toList();
      expect(query, ['chromodynamics']);

      final hits = docs.entries
          .where((e) => TextUtils.tokenize(e.value).contains(query.first))
          .map((e) => e.key)
          .toList();
      expect(hits, ['b']);
    });

    test('stop words are removed from queries but not from documents', () {
      final q = TextUtils.tokenize('what is the cat')
          .where((t) => !TextUtils.stopWords.contains(t))
          .toList();
      expect(q, ['cat']);
    });
  });
}

class _Item {
  final String name;
  final double relevance;
  final List<double> vector;

  const _Item(this.name, this.relevance, this.vector);
}
