/// LLM service using llama.cpp via FFI.
///
/// Wraps the `llama_cpp_dart` package (verified API for v0.2.x):
///   Llama.libraryPath = "...";
///   final llama = Llama(path);
///   llama.setPrompt(prompt);
///   var (token, done) = llama.getNext();
///   llama.dispose();
///
/// NOTE: the Android build must also ship the compiled `libllama.so`
/// (built from ggml-org/llama.cpp with the Android NDK). If the shared
/// library is absent, [loadModel] returns false and [onError] is invoked
/// instead of crashing the app.
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

class LlmService {
  static LlmService? _instance;

  Llama? _llama;
  String? _modelPath;
  bool _isLoaded = false;
  int _nCtx = 2048;

  /// Optional streaming hooks.
  void Function(String token)? onToken;
  void Function(String error)? onError;

  LlmService._();

  static LlmService getInstance() => _instance ??= LlmService._();

  /// Point the binding at a custom shared library (Android: "libllama.so").
  static void setLibraryPath(String path) {
    Llama.libraryPath = path;
  }

  /// Load a GGUF model. Returns true on success.
  Future<bool> loadModel(String modelPath, {int nCtx = 2048}) async {
    try {
      await release();
      _nCtx = nCtx;
      // The synchronous `Llama` wrapper is used so token streaming can be
      // exposed as a plain Dart Stream without isolate plumbing.
      _llama = Llama(modelPath);
      _modelPath = modelPath;
      _isLoaded = true;
      return true;
    } catch (e) {
      onError?.call('Failed to load model: $e');
      _isLoaded = false;
      _llama = null;
      return false;
    }
  }

  /// Stream generated tokens one at a time.
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
  }) async* {
    final llama = _llama;
    if (!_isLoaded || llama == null) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }

    llama.setPrompt(prompt);

    var emitted = 0;
    while (emitted < maxTokens) {
      final (String token, bool done) = llama.getNext();
      if (done) break;
      if (token.isEmpty) continue;
      onToken?.call(token);
      yield token;
      emitted++;
    }
  }

  /// Convenience wrapper that collects the whole response.
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
  }) async {
    final buffer = StringBuffer();
    await for (final token
        in generateStream(prompt: prompt, maxTokens: maxTokens)) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  /// Free native resources.
  Future<void> release() async {
    try {
      _llama?.dispose();
    } catch (_) {
      // Already disposed / never initialised.
    }
    _llama = null;
    _isLoaded = false;
    _modelPath = null;
  }

  bool get isLoaded => _isLoaded;
  String? get modelPath => _modelPath;
  int get contextSize => _nCtx;
}
