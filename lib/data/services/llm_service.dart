/// LLM + vision service — local GGUF inference via llama.cpp.
///
/// Backed by `native_llama`, which vendors the whole llama.cpp tree (tools/mtmd
/// included) inside its pub archive so the NDK genuinely compiles libllama.so
/// into the APK. That detail is not cosmetic: `llama_cpp_dart` and
/// `flutter_llama` both point their CMake config at a `llama.cpp/` directory
/// that is absent from the published archive — the build succeeds and then the
/// app fails at runtime because the native library was never packaged.
///
/// Native surface used here:
///   final llm = NativeLlama();
///   await llm.initModel(path, nCtx: 4096, nGpuLayers: 99);
///   await llm.initVision(mmprojPath);           // enables image input
///   llm.generateResponse(msgs, mediaPaths: [jpg]).listen(print);
///
/// Public surface used by the rest of the app:
///   bool isLoaded · Future<bool> loadModel(String) · Stream<String> generateStream(...)
///   Future<String> generate(...) · Future<bool> loadVision(...) · Future<String> describeImage(...)
///   Future<void> stop() · Future<void> release()
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:native_llama/native_llama.dart';

import '../../domain/models/local_model.dart';

class LlmService {
  static LlmService? _instance;

  final NativeLlama _llm = NativeLlama();

  String? _modelPath;
  bool _isLoaded = false;
  int _nCtx = 2048;

  String? _visionProjectorPath;
  bool _isVisionLoaded = false;

  /// Fires for every generated token (same data as the stream).
  void Function(String token)? onToken;

  /// Fires instead of throwing so the UI can surface a message.
  void Function(String error)? onError;

  LlmService._();

  static LlmService getInstance() => _instance ??= LlmService._();

  /// Number of usable CPU cores — the plugin picks thread count from this.
  Future<int> cpuCores() async {
    try {
      return await _llm.getCpuCores();
    } catch (_) {
      return 4;
    }
  }

  /// Load a GGUF chat model. Returns false (and reports via [onError]) on
  /// failure rather than throwing, so the UI can show a message.
  ///
  /// [gpuLayers] is passed straight through; the plugin's CMake bakes in
  /// `GGML_USE_VULKAN=1`, so anything above 0 engages GPU offload when the
  /// device exposes a working Vulkan driver.
  Future<bool> loadModel(
    String modelPath, {
    int nCtx = 2048,
    int gpuLayers = 99,
  }) async {
    try {
      await release();
      _nCtx = nCtx;

      await _llm.initModel(
        modelPath,
        nCtx: nCtx,
        nThreads: await cpuCores(),
        nGpuLayers: gpuLayers,
      );

      _modelPath = modelPath;
      _isLoaded = true;
      debugPrint('[LlmService] loaded $modelPath (ctx=$nCtx, gpuLayers=$gpuLayers)');
      return true;
    } catch (e) {
      onError?.call('Failed to load model: $e');
      _isLoaded = false;
      _modelPath = null;
      return false;
    }
  }

  /// Load the mmproj projector that makes a vision model usable.
  ///
  /// Kept separate from [loadModel] because the projector belongs to the vision
  /// model, not the chat model, and the two are downloaded independently.
  Future<bool> loadVision(String mmprojPath) async {
    try {
      await _llm.initVision(mmprojPath);
      _visionProjectorPath = mmprojPath;
      _isVisionLoaded = true;
      debugPrint('[LlmService] vision projector loaded: $mmprojPath');
      return true;
    } catch (e) {
      onError?.call('Failed to load vision projector: $e');
      _isVisionLoaded = false;
      _visionProjectorPath = null;
      return false;
    }
  }

  /// Turn a list of messages into the plugin's wire format.
  static List<Map<String, String>> _wire(
    String prompt, {
    String? systemPrompt,
    List<Map<String, String>> history = const [],
  }) {
    return [
      if (systemPrompt != null)
        {'role': 'system', 'content': systemPrompt},
      ...history,
      {'role': 'user', 'content': prompt},
    ];
  }

  /// Stream generated tokens one at a time.
  ///
  /// Pass [imagePath] to feed a picture to a vision model — requires
  /// [isVisionLoaded], otherwise the image is silently dropped by the plugin.
  Stream<String> generateStream({
    required String prompt,
    int maxTokens = 512,
    String? systemPrompt,
    List<Map<String, String>> history = const [],
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    String? imagePath,
  }) async* {
    if (!_isLoaded) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }

    try {
      final out = _llm.generateResponse(
        _wire(prompt, systemPrompt: systemPrompt, history: history),
        mediaPaths: imagePath == null ? null : [imagePath],
        temperature: temperature,
        topP: topP,
        topK: topK,
      );

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
    List<Map<String, String>> history = const [],
    String? imagePath,
  }) async {
    final buffer = StringBuffer();
    await for (final token in generateStream(
      prompt: prompt,
      systemPrompt: systemPrompt,
      history: history,
      imagePath: imagePath,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  /// Ask the currently loaded vision model to describe [imagePath].
  Future<String> describeImage(
    String imagePath, {
    String instruction = 'Describe this image in detail.',
  }) {
    return generate(prompt: instruction, imagePath: imagePath);
  }

  /// Interrupt an in-flight generation.
  Future<void> stop() async {
    try {
      await _llm.abortGeneration();
    } catch (_) {
      // Nothing running.
    }
  }

  /// Free native resources.
  Future<void> release() async {
    try {
      await _llm.dispose();
    } catch (_) {
      // Already disposed / never initialised.
    }
    _isLoaded = false;
    _modelPath = null;
    _isVisionLoaded = false;
    _visionProjectorPath = null;
  }

  bool get isLoaded => _isLoaded;
  String? get modelPath => _modelPath;
  int get contextSize => _nCtx;
  bool get isVisionLoaded => _isVisionLoaded;
  String? get visionProjectorPath => _visionProjectorPath;

  /// True when [model] can answer image questions in the current session.
  bool canSee(LocalModel model) => _isLoaded && _isVisionLoaded && model.isVision;
}