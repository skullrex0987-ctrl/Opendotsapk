/// Small text utilities shared by the RAG and document pipelines.
///
/// Deliberately dependency-free: this runs on-device next to an LLM, so the
/// code must stay cheap and predictable.
library;

import 'dart:math' as math;

class TextUtils {
  TextUtils._();

  /// Rough English stop-word set. Used only to down-weight query terms during
  /// keyword scoring — never to drop content from stored documents.
  static const Set<String> stopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'but',
    'by',
    'for',
    'from',
    'had',
    'has',
    'have',
    'he',
    'her',
    'his',
    'i',
    'if',
    'in',
    'into',
    'is',
    'it',
    'its',
    'me',
    'my',
    'no',
    'not',
    'of',
    'on',
    'or',
    'our',
    'so',
    'that',
    'the',
    'their',
    'them',
    'then',
    'there',
    'these',
    'they',
    'this',
    'to',
    'was',
    'we',
    'were',
    'what',
    'when',
    'where',
    'which',
    'who',
    'will',
    'with',
    'you',
    'your',
  };

  /// Lowercase word tokens, keeping intra-word apostrophes and digits.
  ///
  /// `"don't"` stays one token; `"gpt-4"` becomes `gpt` and `4`, which is the
  /// behaviour BM25 wants for technical text.
  static List<String> tokenize(String text) {
    final out = <String>[];
    final buf = StringBuffer();

    void flush() {
      if (buf.isEmpty) return;
      final t = buf.toString();
      buf.clear();
      if (t.isNotEmpty) out.add(t);
    }

    for (final rune in text.toLowerCase().runes) {
      final c = String.fromCharCode(rune);
      final isWord = RegExp(r'[a-z0-9\u00c0-\u024f]').hasMatch(c);
      if (isWord || (c == "'" && buf.isNotEmpty)) {
        buf.write(c);
      } else {
        flush();
      }
    }
    flush();

    // Trim trailing apostrophes so "dogs'" == "dogs".
    return out
        .map((t) => t.replaceAll(RegExp(r"^'+|'+$"), ''))
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// Term-frequency map, used for BM25 scoring.
  static Map<String, int> termFrequencies(List<String> tokens) {
    final tf = <String, int>{};
    for (final t in tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
    return tf;
  }

  /// Cosine similarity between two equal-length vectors.
  ///
  /// Embeddings from `all-MiniLM-L6-v2` arrive L2-normalised, so this is
  /// usually just a dot product — the magnitudes are computed anyway so the
  /// function stays correct if a model ever returns unnormalised vectors.
  static double cosine(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final n = math.min(a.length, b.length);
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < n; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  /// Characters a chunk may hold, sized to the embedder.
  ///
  /// The ONNX embedder (all-MiniLM-L6-v2) truncates at 128 tokens. At roughly
  /// four characters per token that is close to 512 characters, and chunks used
  /// to be 900 — so the tail of every chunk was silently never embedded and
  /// could never be retrieved. 480 keeps headroom for tokenizer variance and
  /// for denser stretches of text.
  static const int embedChunkChars = 480;

  /// Overlap between neighbouring chunks — 20% of [embedChunkChars].
  ///
  /// A fact sitting exactly on a boundary is invisible to both neighbours
  /// without this.
  static const int embedChunkOverlap = 96;

  /// Split [text] into overlapping windows on paragraph/sentence boundaries.
  ///
  /// Overlap matters for retrieval: a fact sitting on a chunk boundary is
  /// otherwise invisible to both neighbours. Boundaries are preferred over
  /// hard character cuts so chunks stay readable when shown as citations.
  static List<String> chunk(
    String text, {
    int targetChars = embedChunkChars,
    int overlapChars = embedChunkOverlap,
  }) {
    final clean = text.replaceAll('\r\n', '\n').trim();
    if (clean.isEmpty) return const [];
    if (clean.length <= targetChars) return [clean];

    // Split into paragraphs, then sentences, so we never cut mid-sentence
    // unless a single sentence is longer than the whole window.
    final units = <String>[];
    for (final para in clean.split(RegExp(r'\n\s*\n'))) {
      final p = para.trim();
      if (p.isEmpty) continue;
      if (p.length <= targetChars) {
        units.add(p);
        continue;
      }
      for (final sentence in p.split(RegExp(r'(?<=[.!?])\s+'))) {
        final s = sentence.trim();
        if (s.isEmpty) continue;
        if (s.length <= targetChars) {
          units.add(s);
        } else {
          // Pathological single sentence: fall back to hard windows.
          for (var i = 0; i < s.length; i += targetChars) {
            units.add(s.substring(i, math.min(i + targetChars, s.length)));
          }
        }
      }
    }

    final chunks = <String>[];
    var current = StringBuffer();

    void emit() {
      final c = current.toString().trim();
      if (c.isNotEmpty) chunks.add(c);
      current = StringBuffer();
    }

    for (final u in units) {
      if (current.isEmpty) {
        current.write(u);
        continue;
      }
      if (current.length + 1 + u.length <= targetChars) {
        current.write('\n');
        current.write(u);
      } else {
        final prev = current.toString();
        emit();
        // Carry a tail of the previous chunk forward for context.
        if (overlapChars > 0 && prev.length > overlapChars) {
          current.write(prev.substring(prev.length - overlapChars));
          current.write('\n');
        }
        current.write(u);
      }
    }
    emit();
    return chunks;
  }

  /// Trim a string to [max] characters on a word boundary.
  static String ellipsize(String s, int max) {
    if (s.length <= max) return s;
    final cut = s.substring(0, max);
    final sp = cut.lastIndexOf(' ');
    return '${sp > max * 0.6 ? cut.substring(0, sp) : cut}…';
  }

  /// Estimate token count without loading a tokenizer.
  ///
  /// ~4 characters per token is close enough for English; this is used for
  /// budgeting display and RAG context, never for exact truncation.
  static int estimateTokens(String text) => (text.length / 4).ceil();
}
