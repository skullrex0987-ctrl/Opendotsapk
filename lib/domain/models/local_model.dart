/// Selectable on-device model catalog.
///
/// Every entry here is a **GGUF** file loadable by llama.cpp. The app downloads
/// the user's chosen model at runtime (Settings -> Models), so nothing is
/// bundled in the APK and the user decides the size/quality trade-off.
///
/// NOTE ON NEEDLE (Cactus): it is deliberately absent. Cactus ships Needle as
/// `.cact` + `.safetensors` plus its own native runtime (`libneedle.a`) — it is
/// NOT a GGUF and cannot be loaded through llama.cpp. Supporting it would mean
/// embedding a completely separate inference engine.
library;

enum ModelKind { llm, vision }

class LocalModel {
  /// Stable id persisted in settings.
  final String id;
  final String displayName;

  /// One-line description shown in the picker.
  final String description;

  final ModelKind kind;

  /// Primary weight file.
  final String fileName;
  final String url;
  final int approxBytes;

  /// Vision models additionally need a CLIP/mmproj projector file.
  final String? projectorFileName;
  final String? projectorUrl;

  /// Recommended context window for this model.
  final int contextSize;

  /// Rough RAM needed at runtime, for display.
  final String ramHint;

  const LocalModel({
    required this.id,
    required this.displayName,
    required this.description,
    required this.kind,
    required this.fileName,
    required this.url,
    required this.approxBytes,
    this.projectorFileName,
    this.projectorUrl,
    this.contextSize = 2048,
    this.ramHint = '',
  });

  bool get isVision => kind == ModelKind.vision;

  String get sizeLabel {
    if (approxBytes >= 1 << 30) {
      return '${(approxBytes / (1 << 30)).toStringAsFixed(2)} GB';
    }
    return '${(approxBytes / (1 << 20)).round()} MB';
  }

  /// All remote files this model needs.
  List<({String name, String url})> get files => [
        (name: fileName, url: url),
        if (projectorFileName != null && projectorUrl != null)
          (name: projectorFileName!, url: projectorUrl!),
      ];
}

class ModelCatalog {
  ModelCatalog._();

  // ------------------------------------------------------------- chat models
  static const LocalModel qwen05b = LocalModel(
    id: 'qwen2.5-0.5b-instruct-q4_k_m',
    displayName: 'Qwen2.5 0.5B Instruct',
    description: 'Smallest Qwen. Good tool-calling, very low RAM.',
    kind: ModelKind.llm,
    fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    url: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    approxBytes: 397000000,
    contextSize: 4096,
    ramHint: '~600 MB',
  );

  static const LocalModel smolLm2_360m = LocalModel(
    id: 'smollm2-360m-instruct-q8_0',
    displayName: 'SmolLM2 360M Instruct',
    description: 'Fastest option. Q8 precision, best for quick replies.',
    kind: ModelKind.llm,
    fileName: 'smollm2-360m-instruct-q8_0.gguf',
    url: 'https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct-GGUF/resolve/main/smollm2-360m-instruct-q8_0.gguf',
    approxBytes: 386000000,
    contextSize: 2048,
    ramHint: '~550 MB',
  );

  static const LocalModel qwen15b = LocalModel(
    id: 'qwen2.5-1.5b-instruct-q4_k_m',
    displayName: 'Qwen2.5 1.5B Instruct',
    description: 'Best quality. Needs more RAM and a faster phone.',
    kind: ModelKind.llm,
    fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    url: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    approxBytes: 1120000000,
    contextSize: 4096,
    ramHint: '~1.4 GB',
  );

  // ----------------------------------------------------------- vision model
  static const LocalModel moondream2 = LocalModel(
    id: 'moondream2-q5k',
    displayName: 'Moondream2 (vision)',
    description: 'Image understanding + captioning. Ships with projector.',
    kind: ModelKind.vision,
    fileName: 'moondream2-050824-q5k.gguf',
    url: 'https://huggingface.co/cjpais/moondream2-llamafile/resolve/main/moondream2-050824-q5k.gguf',
    approxBytes: 1300000000,
    projectorFileName: 'moondream2-mmproj-050824-f16.gguf',
    projectorUrl: 'https://huggingface.co/cjpais/moondream2-llamafile/resolve/main/moondream2-mmproj-050824-f16.gguf',
    contextSize: 2048,
    ramHint: '~1.6 GB',
  );

  /// Models the user can pick as the chat brain.
  static const List<LocalModel> llms = [qwen05b, smolLm2_360m, qwen15b];

  /// Models the user can pick for image understanding.
  static const List<LocalModel> visionModels = [moondream2];

  static const List<LocalModel> all = [qwen05b, smolLm2_360m, qwen15b, moondream2];

  static LocalModel? byId(String? id) {
    if (id == null) return null;
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Default chat model (smallest that still does tool calls well).
  static const LocalModel defaultLlm = qwen05b;

  /// Deliberately unsupported, documented so the UI can explain why.
  static const String needleNote =
      'Needle (Cactus) is not GGUF — it needs the Cactus native runtime, '
      'so it cannot be loaded through llama.cpp.';
}
