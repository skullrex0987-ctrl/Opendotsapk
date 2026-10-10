/// LLM service — local GGUF text inference via llama.cpp.
///
/// Backed by `llama_flutter_android`, which bundles the llama.cpp source tree
/// in its pub archive so the NDK actually compiles `libllama.so` into the APK.
/// That detail is not cosmetic: `llama_cpp_dart` and `flutter_llama` both point
/// their CMake config at a `llama.cpp/` directory that is absent from the
/// published archive — the build succeeds and then the app fails at runtime
/// because the native library was never packaged.
///
/// **Vision is not supported on this binding.** It ships no mtmd code, so a
/// projector can never be bound and images cannot be passed to the model.
/// `native_llama` does vendor mtmd and would fix that, but its link line is
/// `llama dl vulkan` and NDK r28 fails with hundreds of
/// `undefined symbol: div_f32_f16_f32_len` (ggml CPU backend) errors — so it
/// is not wired up here. [loadVision] says so out loud rather than failing
/// silently deep inside generation.
///
/// Native surface used here:
///   final c = LlamaController();
///   await c.loadModel(modelPath: path, contextSize: 4096, gpuLayers: 99);
///   c.generate(prompt: 'hi').listen(print);
///
/// Public surface used by the rest of the app:
///   bool isLoaded · Future<bool> loadModel(String) · Stream<String> generateStream(...)
///   Future<String> generate(...) · Future<bool> loadVision(...) · Future<String> describeImage(...)
///   Future<void> stop() · Future<void> release() · Future<GpuInfo> detectGpu()
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

class LlmService {
  static LlmService? _instance;

  final LlamaController _llm = LlamaController();

  String? _modelPath;
  bool _isLoaded = false;
  int _nCtx = 2048;

  /// True when a vision projector is attached.
  ///
  /// Always false on the llama_flutter_android binding: that plugin ships no
  /// mtmd code at all, so there is no way to feed an image to a model. Kept as
  /// real state rather than a hardcoded false so swapping in an mtmd-capable
  /// binding (see the pubspec notes) needs no call-site changes.
  bool _isVisionLoaded = false;
  String? _visionProjectorPath;

  /// Fires for every generated token (same data as the stream).
  void Function(String token)? onToken;

  /// Fires instead of throwing so the UI can surface a message.
  void Function(String error)? onError;

  LlmService._();

  static LlmService getInstance() => _instance ??= LlmService._();

  /// GPU capability of the current device.
  Future<GpuInfo> detectGpu() async {
    try {
      return await _llm.detectGpu();
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

  /// Load a GGUF chat model. Returns false (and reports via [onError]) on
  /// failure rather than throwing, so the UI can show a message.
  ///
  /// [gpuLayers] defaults to 0 because the native build compiles the Vulkan
  /// backend out (see scripts/patch_native_llama.py), so there is no GPU
  /// backend to offload to. Inference runs on llama.cpp's CPU kernels, which is
  /// the right call for the 0.5B-class models this app ships anyway.
  Future<bool> loadModel(
    String modelPath, {
    int nCtx = 2048,
    int gpuLayers = 0,
  }) async {
    try {
      await release();
      _nCtx = nCtx;

      // Offload whatever the device can actually hold; falls back to 0 (CPU).
      var layers = gpuLayers;
      try {
        layers = (await _llm.detectGpu()).recommendedGpuLayers;
      } catch (_) {
        layers = 0;
      }

      await _llm.loadModel(
        modelPath: modelPath,
        contextSize: nCtx,
        gpuLayers: layers,
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

  /// Attach a vision projector so the model can read images.
  ///
  /// Not supported on this binding: llama_flutter_android ships no mtmd code,
  /// so a projector can never be bound. Returns false rather than pretending.
  /// [mmprojPath] is validated anyway so a broken download is caught here and
  /// not three layers deeper.
  Future<bool> loadVision(String mmprojPath) async {
    if (!await File(mmprojPath).exists()) {
      onError?.call('Projector file missing: $mmprojPath');
      _isVisionLoaded = false;
      _visionProjectorPath = null;
      return false;
    }
    onError?.call(
      'Vision is not supported by this build: the llama.cpp binding ships '
      'without mtmd. Run the text model only.',
    );
    _isVisionLoaded = false;
    _visionProjectorPath = null;
    return false;
  }

  /// Turn raw prompt text into the plugin's chat-message list.
  static List<ChatMessage> _wire(
    String prompt, {
    String? systemPrompt,
    List<ChatMessage> history = const [],
  }) {
    return [
      if (systemPrompt != null)
        ChatMessage(role: 'system', content: systemPrompt),
      ...history,
      ChatMessage(role: 'user', content: prompt),
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
    List<ChatMessage> history = const [],
    double temperature = 0.7,
    double topP = 0.9,
    int topK = 40,
    String? imagePath,
  }) async* {
    if (!_isLoaded) {
      throw StateError('Model not loaded. Call loadModel() first.');
    }
    if (imagePath != null) {
      throw UnsupportedError(
        'This build cannot pass images to the model (no mtmd in the binding).',
      );
    }

    try {
      final messages = _wire(prompt, systemPrompt: systemPrompt, history: history);
      final out = _llm.generateChat(
        messages: messages,
        maxTokens: maxTokens,
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
    List<ChatMessage> history = const [],
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

  /// Ask the loaded model to describe [imagePath].
  ///
  /// Throws [UnsupportedError] on this binding rather than returning a made-up
  /// description — a hallucinated image caption is worse than an error.
  Future<String> describeImage(
    String imagePath, {
    String instruction = 'Describe this image in detail.',
  }) async {
    if (!_isVisionLoaded) {
      throw UnsupportedError(
        'Vision is unavailable: this build ships no mtmd support.',
      );
    }
    return generate(prompt: instruction, imagePath: imagePath);
  }

  /// Interrupt an in-flight generation.
  Future<void> stop() async {
    try {
      await _llm.stop();
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

}