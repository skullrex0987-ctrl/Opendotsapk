/// Embedding service using ONNX Runtime.
///
/// Wraps the `onnxruntime` package (verified API for v1.4.x):
///   OrtEnv.instance.init();
///   final session = OrtSession.fromBuffer(bytes, OrtSessionOptions()!);
///   final input = OrtValueTensor.createTensorWithDataList(data, shape);
///   final outputs = await session.runAsync(OrtRunOptions(), {'input_ids': input});
///
/// The model is expected to be an all-MiniLM-L6-v2 style encoder exported to
/// ONNX with int64 inputs `input_ids` + `attention_mask` and a float output
/// including a `sentence_embedding` (or `last_hidden_state`) tensor.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

class EmbeddingService {
  static EmbeddingService? _instance;

  OrtSession? _session;
  bool _isLoaded = false;
  int _dim = 384;
  int _maxTokens = 128;

  /// WordPiece vocabulary (token -> id) when a `vocab.txt` sits beside the
  /// model. Without it the fallback hash tokenizer is used, which is enough to
  /// keep the pipeline running but degrades retrieval quality.
  Map<String, int>? _vocab;

  EmbeddingService._();

  static EmbeddingService getInstance() => _instance ??= EmbeddingService._();

  /// Load an ONNX encoder from an absolute file path.
  Future<bool> loadModel(String modelPath, {int dimension = 384}) async {
    try {
      _dim = dimension;
      OrtEnv.instance.init();

      final bytes = await File(modelPath).readAsBytes();
      final options = OrtSessionOptions();
      _session = OrtSession.fromBuffer(bytes, options);
      _isLoaded = true;

      // Optional WordPiece vocab, loaded from the model's directory.
      final vocabFile = File(
        '${File(modelPath).parent.path}${Platform.pathSeparator}vocab.txt',
      );
      if (await vocabFile.exists()) {
        _vocab = await _loadVocab(vocabFile);
      }
      return true;
    } catch (e) {
      _isLoaded = false;
      _session = null;
      return false;
    }
  }

  Future<Map<String, int>> _loadVocab(File file) async {
    final lines = await file.readAsLines();
    final map = <String, int>{};
    for (var i = 0; i < lines.length; i++) {
      final token = lines[i].trim();
      if (token.isNotEmpty) map[token] = i;
    }
    return map;
  }

  /// Embed a single string. Returns an L2-normalised vector of length [_dim].
  Future<List<double>> generateEmbedding(String text) async {
    final session = _session;
    if (!_isLoaded || session == null) {
      throw StateError('Embedding model not loaded');
    }

    final ids = _tokenize(text);
    final shape = <int>[1, ids.length];

    final inputIds = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(ids),
      shape,
    );
    final attentionMask = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(List<int>.filled(ids.length, 1)),
      shape,
    );

    final inputs = <String, OrtValue>{
      'input_ids': inputIds,
      'attention_mask': attentionMask,
    };
    final runOptions = OrtRunOptions();

    try {
      final outputs = await session.runAsync(runOptions, inputs);
      if (outputs == null || outputs.isEmpty) return List<double>.filled(_dim, 0.0);

      // Prefer a pooled sentence embedding when the model exposes one,
      // otherwise mean-pool the token-level output.
      final dynamic first = outputs.first.value;
      final flat = _flatten(first);
      if (flat.length == _dim) return _normalise(flat);
      return _meanPoolAndNormalise(flat, ids.length);
    } finally {
      inputIds.release();
      attentionMask.release();
    }
  }

  /// Embed several strings (sequential — keeps peak memory low on phones).
  Future<List<List<double>>> generateEmbeddings(List<String> texts) async {
    final out = <List<double>>[];
    for (final t in texts) {
      out.add(await generateEmbedding(t));
    }
    return out;
  }

  /// Depth-first flatten of a nested List<dynamic> into doubles.
  List<double> _flatten(dynamic value, [List<double>? acc]) {
    final out = acc ?? <double>[];
    if (value is List) {
      for (final v in value) {
        _flatten(v, out);
      }
    } else if (value is num) {
      out.add(value.toDouble());
    }
    return out;
  }

  /// Mean-pool a [tokens x dim] matrix and normalise.
  List<double> _meanPoolAndNormalise(List<double> flat, int tokens) {
    if (tokens <= 0 || flat.length < tokens * _dim) {
      final v = List<double>.filled(_dim, 0.0);
      for (var i = 0; i < _dim && i < flat.length; i++) {
        v[i] = flat[i];
      }
      return _normalise(v);
    }
    final v = List<double>.filled(_dim, 0.0);
    for (var t = 0; t < tokens; t++) {
      final base = t * _dim;
      for (var d = 0; d < _dim; d++) {
        v[d] += flat[base + d];
      }
    }
    for (var d = 0; d < _dim; d++) {
      v[d] /= tokens;
    }
    return _normalise(v);
  }

  List<double> _normalise(List<double> v) {
    var sum = 0.0;
    for (final x in v) {
      sum += x * x;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) return v;
    for (var i = 0; i < v.length; i++) {
      v[i] = v[i] / norm;
    }
    return v;
  }

  /// WordPiece tokenisation when a vocab is available, else a stable hash.
  List<int> _tokenize(String text) {
    final vocab = _vocab;
    final lower = text.toLowerCase().trim();
    if (lower.isEmpty) return <int>[0];

    if (vocab == null) {
      // Fallback: deterministic hash bucketing. Keeps the app functional but
      // is NOT semantically meaningful — ship vocab.txt for real quality.
      final words = lower.split(RegExp(r'\s+'));
      final ids = <int>[101];
      for (final w in words) {
        ids.add(w.hashCode.abs() % 30000);
      }
      ids.add(102);
      return ids.length > _maxTokens ? ids.sublist(0, _maxTokens) : ids;
    }

    final ids = <int>[vocab['[CLS]'] ?? 101];
    for (final word in lower.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      var start = 0;
      var pieces = <String>[];
      var ok = true;
      while (start < word.length) {
        var end = word.length;
        String? cur;
        while (start < end) {
          var sub = word.substring(start, end);
          if (start > 0) sub = '##$sub';
          if (vocab.containsKey(sub)) {
            cur = sub;
            break;
          }
          end--;
        }
        if (cur == null) {
          ok = false;
          break;
        }
        pieces.add(cur);
        start = end;
      }
      if (!ok) pieces = <String>['[UNK]'];
      for (final p in pieces) {
        ids.add(vocab[p] ?? vocab['[UNK]'] ?? 100);
      }
    }
    ids.add(vocab['[SEP]'] ?? 102);
    return ids.length > _maxTokens ? ids.sublist(0, _maxTokens) : ids;
  }

  Future<void> release() async {
    _session = null;
    _isLoaded = false;
  }

  bool get isLoaded => _isLoaded;
  int get dimension => _dim;
}
