/// LLM + vision service — local GGUF inference via llama.cpp.
///
/// Backed by `native_llama`, which vendors the whole llama.cpp tree (tools/mtmd
/// included) inside its pub archive so the NDK genuinely compiles libllama.so
/// into the APK. That detail is not cosmetic: `llama_cpp_dart` and
/// `flutter_llama` both point their CMake config at a `llama.cpp/` directory
/// that is absent from the published archive — the build succeeds and then the
/// app fails at runtime because the native library was never packaged.
///
/// ## The wire format is `text`, not `content`
///
/// `NativeLlama.generateResponse` does `messages.map((m) => m['text']!)`. Note
/// the `!`. Hand it `{'role':…, 'content':…}` — the OpenAI spelling, and the
/// obvious guess — and it throws a null-assertion *inside the stream
/// controller's onListen callback*, before `startGeneration` is ever invoked.
/// Nothing catches that: the error escapes as an unhandled zone error instead
/// of reaching the `await for` on the caller's side, and because the controller
/// is never closed the consuming stream simply never completes. The symptom is
/// a chat that sits on "Thinking…" forever with no error anywhere.
///
/// That is a genuinely nasty failure mode, so two things are true of this file:
/// the key is `text`, and nothing here is allowed to await a stream that has no
/// bound on how long it may stay silent. See [_generationTimeout].
///
/// ## There is no token cap in the plugin
///
/// `generateResponse` accepts no `nPredict`/`maxTokens`, and the native loop in
/// `native-lib.cpp` runs `while (true)` until it hits an end-of-generation token
/// or fills the context window — at which point it discards the older half and
/// keeps going. A model that fails to emit EOG therefore generates until the
/// user interrupts. [maxTokens] is enforced here, on the Dart side, by aborting
/// the native generation once the count is reached.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:native_llama/native_llama.dart';

import '../../core/utils/log.dart';
import '../../domain/models/local_model.dart';

/// How long a generation may go without producing a single token before it is
/// treated as wedged.
///
/// This is the safety net for the class of bug described in the library
/// docstring: anything that stops the native side from ever emitting
/// `__END_OF_STREAM__` would otherwise hang the UI permanently. Prompt
/// processing on a large model can legitimately take a while before the first
/// token, so this is deliberately generous.
const Duration _generationTimeout = Duration(seconds: 90);

/// Hard ceiling on wall-clock time for one generation, regardless of progress.
const Duration _totalGenerationTimeout = Duration(minutes: 5);

class LlmService {
  static LlmService? _instance;

  final NativeLlama _llm = NativeLlama();

  String? _modelPath;
  bool _isLoaded = false;
  int _nCtx = 2048;
  int _gpuLayers = 0;

  String? _visionProjectorPath;
  bool _isVisionLoaded = false;

  /// True while a generation is in flight, so the UI can offer "Stop".
  bool _isGenerating = false;

  /// Fires for every generated token (same data as the stream).
  void Function(String token)? onToken;

  /// Fires instead of throwing so the UI can surface a message.
  void Function(String error)? onError;

  LlmService._();

  static LlmService getInstance() => _instance ??= LlmService._();

  /// Number of usable CPU cores for inference.
  ///
  /// [performanceOnly] asks the platform for the big cores only. On the
  /// big.LITTLE Android SoCs this app targets, handing llama.cpp every core
  /// including the little ones tends to *reduce* throughput, because the slow
  /// cores become the stragglers in every synchronised matmul.
  ///
  /// The result is capped at [_maxInferenceThreads]. Decode is memory-bandwidth
  /// bound, so past roughly four threads the extra workers contend for the same
  /// memory bus and generation gets slower rather than faster. The cost is some
  /// prompt-processing throughput, which is the right trade for a chat app
  /// where time-to-first-token and streaming smoothness are what a person
  /// actually notices.
  Future<int> cpuCores({bool performanceOnly = true}) async {
    try {
      final cores = await _llm.getCpuCores(performanceOnly: performanceOnly);
      if (cores <= 0) return 4;
      return cores < _maxInferenceThreads ? cores : _maxInferenceThreads;
    } catch (_) {
      return 4;
    }
  }

  static const int _maxInferenceThreads = 4;

  /// Load a GGUF chat model. Returns false (and reports via [onError]) on
  /// failure rather than throwing, so the UI can show a message.
  ///
  /// [gpuLayers] is how many transformer layers to offload. The value is
  /// advisory: llama.cpp silently falls back to CPU when the backend cannot be
  /// initialised, so an offload request on a device with no usable GPU costs
  /// nothing but a log line. [GpuCapability] decides what to pass.
  Future<bool> loadModel(
    String modelPath, {
    int nCtx = 2048,
    int gpuLayers = 0,
  }) async {
    try {
      await release();
      _nCtx = nCtx;
      _gpuLayers = gpuLayers;

      await _llm.initModel(
        modelPath,
        nCtx: nCtx,
        nThreads: await cpuCores(),
        nGpuLayers: gpuLayers,
      );

      _modelPath = modelPath;
      _isLoaded = true;
      debugPrint(
        '[LlmService] loaded $modelPath (ctx=$nCtx, gpuLayers=$gpuLayers)',
      );
      return true;
    } catch (e) {
      onError?.call('Failed to load model: $e');
      _isLoaded = false;
      _modelPath = null;
      return false;
    }
  }

  /// Why the last [loadVision] call failed, or null if it never has.
  ///
  /// The chat screen shows this instead of a bare "vision failed to attach",
  /// so the user gets an actual cause rather than having to guess.
  String? get lastVisionError => _lastVisionError;
  String? _lastVisionError;

  /// Load the mmproj projector that makes a vision model usable.
  ///
  /// Kept separate from [loadModel] because the projector belongs to the vision
  /// model, not the chat model, and the two are downloaded independently.
  Future<bool> loadVision(String mmprojPath) async {
    try {
      await _llm.initVision(mmprojPath);
      _visionProjectorPath = mmprojPath;
      _isVisionLoaded = true;
      _lastVisionError = null;
      Log.i('[LlmService] vision projector loaded: $mmprojPath');
      return true;
    } catch (e) {
      _isVisionLoaded = false;
      _visionProjectorPath = null;
      // The plugin's own failure text is the only real diagnostic here, so it
      // must reach the log and the UI rather than being replaced by a generic
      // message.
      _lastVisionError = 'Vision projector failed: $e';
      Log.e('$_lastVisionError (path: $mmprojPath)');
      onError?.call(_lastVisionError!);
      return false;
    }
  }

  /// Turn a list of messages into the plugin's wire format.
  ///
  /// The key is `text`. See the library docstring — using `content` here is the
  /// bug that hangs the chat screen with no error. Exposed for the regression
  /// test in `test/llm_wire_format_test.dart`, which exists precisely because
  /// this mistake is invisible until you run it on a device.
  @visibleForTesting
  static List<Map<String, String>> wire(
    String prompt, {
    String? systemPrompt,
    List<Map<String, String>> history = const [],
  }) {
    return [
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        {'role': 'system', 'text': systemPrompt},
      for (final m in history)
        if ((m['text'] ?? m['content'] ?? '').isNotEmpty)
          {
            'role': m['role'] ?? 'user',
            'text': m['text'] ?? m['content'] ?? '',
          },
      {'role': 'user', 'text': prompt},
    ];
  }

  /// Stream generated tokens one at a time.
  ///
  /// Pass [imagePath] to feed a picture to a vision model. This **requires**
  /// [isVisionLoaded]. When it is false we throw instead of proceeding, because
  /// the plugin drops unsupported media silently and the model will then answer
  /// a question it never actually received.
  ///
  /// Stops early once [maxTokens] tokens have been emitted, because the native
  /// loop has no upper bound of its own.
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

    if (!_llm.isInitialized) {
      throw StateError(
        'The native model is not initialised. Reload the model and try again.',
      );
    }

    // Never let a picture disappear. The plugin discards media when no
    // projector is attached, which yields a confident answer to a question the
    // model never actually received.
    if (imagePath != null && !_isVisionLoaded) {
      throw StateError(
        'Cannot send an image: no vision projector is loaded. The picture '
        'would be dropped and the model would answer as if it had seen '
        'nothing. Load a vision model first.',
      );
    }

    final wire = LlmService.wire(
      prompt,
      systemPrompt: systemPrompt,
      history: history,
    );

    if (wire.isEmpty) {
      throw StateError('Nothing to send: the message list is empty.');
    }

    _isGenerating = true;

    // Bridge the plugin's stream so we can impose our own bounds on it.
    final bridge = StreamController<String>();
    StreamSubscription<String>? sub;
    Timer? silenceTimer;
    Timer? totalTimer;
    var emitted = 0;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      silenceTimer?.cancel();
      totalTimer?.cancel();
      if (!bridge.isClosed) bridge.close();
    }

    void fail(Object error) {
      if (finished) return;
      finished = true;
      silenceTimer?.cancel();
      totalTimer?.cancel();
      if (!bridge.isClosed) bridge.addError(error);
      if (!bridge.isClosed) bridge.close();
    }

    void resetSilenceTimer() {
      silenceTimer?.cancel();
      silenceTimer = Timer(_generationTimeout, () {
        // Nothing has arrived for a long time. Stop the native loop rather than
        // leaving the UI waiting on a stream that may never complete.
        unawaited(stop());
        fail(
          TimeoutException(
            'The model stopped responding. Generation was cancelled after '
            '${_generationTimeout.inSeconds}s without a token.',
          ),
        );
      });
    }

    try {
      // Anything thrown while *building* the stream surfaces here rather than
      // vanishing into onListen, which is the failure the docstring describes.
      final out = _llm.generateResponse(
        wire,
        mediaPaths: imagePath == null ? null : [imagePath],
        temperature: temperature,
        topP: topP,
        topK: topK,
      );

      sub = out.listen(
        (token) {
          if (finished || token.isEmpty) return;
          resetSilenceTimer();

          emitted++;
          onToken?.call(token);
          if (!bridge.isClosed) bridge.add(token);

          if (emitted >= maxTokens) {
            // The plugin will keep going otherwise.
            unawaited(stop());
            finish();
          }
        },
        onError: fail,
        onDone: finish,
        cancelOnError: false,
      );

      totalTimer = Timer(_totalGenerationTimeout, () {
        unawaited(stop());
        fail(
          TimeoutException(
            'Generation exceeded ${_totalGenerationTimeout.inMinutes} minutes '
            'and was cancelled.',
          ),
        );
      });

      resetSilenceTimer();

      await for (final token in bridge.stream) {
        yield token;
      }
    } catch (e) {
      onError?.call('Generation error: $e');
      rethrow;
    } finally {
      finished = true;
      silenceTimer?.cancel();
      totalTimer?.cancel();
      await sub?.cancel();
      if (!bridge.isClosed) await bridge.close();
      _isGenerating = false;
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
      maxTokens: maxTokens,
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
    return generate(prompt: instruction, imagePath: imagePath, maxTokens: 400);
  }

  /// Interrupt an in-flight generation.
  Future<void> stop() async {
    try {
      await _llm.abortGeneration();
    } catch (_) {
      // Nothing running.
    }
    _isGenerating = false;
  }

  /// Free native resources.
  Future<void> release() async {
    await stop();
    try {
      await _llm.dispose();
    } catch (_) {
      // Already disposed / never initialised.
    }
    _isLoaded = false;
    _modelPath = null;
    _isVisionLoaded = false;
    _visionProjectorPath = null;
    _gpuLayers = 0;
  }

  bool get isLoaded => _isLoaded;
  bool get isGenerating => _isGenerating;
  String? get modelPath => _modelPath;
  int get contextSize => _nCtx;
  int get gpuLayers => _gpuLayers;
  bool get isVisionLoaded => _isVisionLoaded;
  String? get visionProjectorPath => _visionProjectorPath;

  /// True when [model] can answer image questions in the current session.
  bool canSee(LocalModel model) => _isLoaded && _isVisionLoaded && model.isVision;
}
