/// LLM service — local GGUF inference via llama.cpp.
///
/// Backed by `llama_flutter_android`, which bundles the full llama.cpp source
/// tree under `android/src/main/cpp/llama.cpp/` and compiles it with the NDK
/// as part of the Gradle build. That matters: `llama_cpp_dart` and
/// `flutter_llama` both point their CMake config at a `llama.cpp` directory
/// that is *not* present in their published pub.dev archives, so the resulting
/// APK ships without `libllama.so` and the LLM silently never loads.
///
/// The controller exposes a token stream over a MethodChannel:
///
///   final gpu = await controller.detectGpu();
///   await controller.loadModel(modelPath: p, gpuLayers: gpu.recommendedGpuLayers);
///   controller.generate(prompt: 'hi').listen(print);
///
/// Public surface used by the rest of the app:
///   bool isLoaded · Future<bool> loadModel(String) · Stream<String> generateStream(...)
///   Future<String> generate(...) · Future<void> release()
library;

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

class LlmService {
  static LlmService? _instance;

  final LlamaController _controller = LlamaController();

  String? _modelPath;
  bool _isLoaded = false;
  int _nCtx = 2048;

  /// Fires for every generated token (same data as the stream).
  void Function(String token)? onToken;

  /// Fires instead of throwing so the UI can surface a message.
  void Function(String error)? onError;

  /// Load progress in [0,1] while [loadModel] runs.
  double _loadProgress = 0.0;
  double get loadProgress => _loadProgress;

  LlmService._();

  static LlmService getInstance() => _instance ??= LlmService._();

  /// GPU capability of the current device.
  Future<GpuInfo> detectGpu() async {
    try {
      return await _controller.detectGpu();
    } catch (e) {
      onError?.call('GPU detection failed: $e');
      return GpuInfo(
        vulkanSupported: false,
        gpuName: 'CPU (unknown)',
        vulkanApiVersion: -1,
        deviceLocalMemoryBytes: -1,
        freeRamBytes: -1,
        recommendedGpuLayers: 0,
      );
    }
  }

  /// Load a GGUF model. Returns false (and reports via [onError]) on failure.
  Future<bool> loadModel(String modelPath, {int nCtx = 2048}) async {
    _loadProgress = 0.0;
    try {
      await release();
      _nCtx = nCtx;

      // Offload whatever the device can actually hold; falls back to 0 (CPU).
      var gpuLayers = 0;
      try {
        final gpu = await _controller.detectGpu();
        gpuLayers = gpu.recommendedGpuLayers;
      } catch (_) {
        // CPU-only path.
      }

      final progress = _controller.loadProgress.listen((p) {
        _loadProgress = p;
      });

      try {
        await _controller.loadModel(
          modelPath: modelPath,
          contextSize: nCtx,
          gpuLayers: gpuLayers,
        );
      } finally {
        await progress.cancel();
      }

      _modelPath = modelPath;
      _isLoaded = true;
      _loadProgress = 1.0;
      debugPrint('[LlmService] loaded $modelPath (ctx=$nCtx, gpuLayers=$gpuLayers)');
      return true;
    } catch (e) {
      onError?.call('Failed to load model: $e');
      _isLoaded = false;
      _modelPath = null;
      return false;
    }
  }

  /// Stream generated tokens one at a time.
  ///
  /// [systemPrompt] and [history] are applied through the model's own chat
  /// template when supplied; otherwise the raw [prompt] is used.
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    String? systemPrompt,
    List<ChatMessage> history = const [],
    double temperature = 0.7,
  }) async* {
    if (!_isLoaded) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }

    try {
      final Stream<String> out;
      if (history.isNotEmpty || systemPrompt != null) {
        final messages = <ChatMessage>[
          if (systemPrompt != null) ChatMessage(role: 'system', content: systemPrompt),
          ...history,
          ChatMessage(role: 'user', content: prompt),
        ];
        out = _controller.generateChat(
          messages: messages,
          maxTokens: maxTokens,
          temperature: temperature,
        );
      } else {
        out = _controller.generate(
          prompt: prompt,
          maxTokens: maxTokens,
          temperature: temperature,
        );
      }

      await for (final token in out) {
        if (token.isEmpty) continue;
        onToken?.call(token);
        yield token;
      }
    } catch (e) {
      onError?.call('Generation error: $e');
      rethrow;
    }
  }

  /// Convenience wrapper that collects the whole response.
  Future<String> generate({
    required String prompt,
    int maxTokens = 512,
    String? systemPrompt,
    List<ChatMessage> history = const [],
  }) async {
    final buffer = StringBuffer();
    await for (final token in generateStream(
      prompt: prompt,
      maxTokens: maxTokens,
      systemPrompt: systemPrompt,
      history: history,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  /// Interrupt an in-flight generation.
  Future<void> stop() async {
    try {
      await _controller.stop();
    } catch (_) {
      // Nothing running.
    }
  }

  /// Free native resources.
  Future<void> release() async {
    try {
      await _controller.dispose();
    } catch (_) {
      // Already disposed / never initialised.
    }
    _isLoaded = false;
    _modelPath = null;
    _loadProgress = 0.0;
  }

  bool get isLoaded => _isLoaded;
  String? get modelPath => _modelPath;
  int get contextSize => _nCtx;

  /// Tokens currently occupying the KV cache, if a model is loaded.
  Future<ContextInfo?> contextInfo() async {
    if (!_isLoaded) return null;
    try {
      return await _controller.getContextInfo();
    } catch (_) {
      return null;
    }
  }
}