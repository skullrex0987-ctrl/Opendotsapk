/// LLM service using llama.cpp via FFI
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

class LlmService {
  static LlmService? _instance;
  LlamaCpp? _llama;
  String? _modelPath;
  bool _isLoaded = false;
  
  // Streaming callbacks
  final void Function(String token)? onToken;
  final void Function(String error)? onError;
  
  LlmService._({this.onToken, this.onError});
  
  static LlmService getInstance() {
    _instance ??= LlmService._();
    return _instance!;
  }
  
  /// Load a GGUF model from path
  Future<bool> loadModel(String modelPath) async {
    try {
      final file = File(modelPath);
      if (!await file.exists()) {
        onError?.call('Model file not found: $modelPath');
        return false;
      }
      
      _modelPath = modelPath;
      
      // Initialize llama.cpp with model
      _llama = await LlamaCpp.initialize(
        modelPath: modelPath,
        params: LlamaParams(
          nCtx: 2048,  // Context size
          nThreads: 2,  // Number of threads
          nBatch: 512,
          nKeep: 256,
        ),
      );
      
      _isLoaded = true;
      return true;
    } catch (e) {
      onError?.call('Failed to load model: $e');
      _isLoaded = false;
      return false;
    }
  }
  
  /// Generate response with streaming
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async {
    if (!_isLoaded || _llama == null) {
      throw Exception('Model not loaded. Call loadModel() first.');
    }
    
    try {
      final result = await _llama!.generate(
        prompt: prompt,
        nPredict: maxTokens,
        temperature: temperature,
        topP: 0.9,
        repeatPenalty: 1.1,
      );
      
      return result;
    } catch (e) {
      onError?.call('Generation error: $e');
      rethrow;
    }
  }
  
  /// Stream generation for real-time token display
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    double temperature = 0.7,
  }) async* {
    if (!_isLoaded || _llama == null) {
      throw Exception('Model not loaded. Call loadModel() first.');
    }
    
    try {
      // Using llama.cpp's sampling callback for streaming
      await for (final token in _llama!.streamGenerate(
        prompt: prompt,
        nPredict: maxTokens,
        temperature: temperature,
      )) {
        onToken?.call(token);
        yield token;
      }
    } catch (e) {
      onError?.call('Stream error: $e');
      rethrow;
    }
  }
  
  /// Get model info
  Map<String, dynamic>? getModelInfo() {
    if (!_isLoaded || _llama == null) return null;
    return {
      'path': _modelPath,
      'loaded': _isLoaded,
      'model': _llama!.getModelName(),
      'nCtx': _llama!.getNCtx(),
    };
  }
  
  /// Release model resources
  Future<void> release() async {
    await _llama?.free();
    _llama = null;
    _isLoaded = false;
    _modelPath = null;
  }
  
  /// Check if model is loaded
  bool get isLoaded => _isLoaded;
  String? get modelPath => _modelPath;
}
