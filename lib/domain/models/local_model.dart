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

enum ModelKind { llm, vision, embedding }

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

  /// Any other files that must sit next to the weights (e.g. a WordPiece
  /// `vocab.txt` for the embedding model).
  final List<({String name, String url, int minBytes})> extraFiles;

  /// Smallest byte count that still counts as a complete copy of a file.
  /// The shared 1 MB floor in [isInstalled] is right for GGUF weights but would
  /// reject a 227 KB `vocab.txt` forever.
  final int minBytes;

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
    this.extraFiles = const [],
    this.minBytes = 1024 * 1024,
    this.contextSize = 2048,
    this.ramHint = '',
  });

  bool get isVision => kind == ModelKind.vision;
  bool get isEmbedding => kind == ModelKind.embedding;

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
        ...extraFiles.map((f) => (name: f.name, url: f.url)),
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
    description: 'Image understanding. Runs on the CPU backend, so expect '
        'slow first-token latency on a phone.',
    kind: ModelKind.vision,
    fileName: 'moondream2-050824-q5k.gguf',
    url: 'https://huggingface.co/cjpais/moondream2-llamafile/resolve/main/moondream2-050824-q5k.gguf',
    approxBytes: 1300000000,
    projectorFileName: 'moondream2-mmproj-050824-f16.gguf',
    projectorUrl: 'https://huggingface.co/cjpais/moondream2-llamafile/resolve/main/moondream2-mmproj-050824-f16.gguf',
    contextSize: 2048,
    ramHint: '~1.6 GB',
  );

  /// --------------------------------------------------------- embedding model
  ///
  /// Verified against the published ONNX graph: inputs are `input_ids`,
  /// `attention_mask` AND `token_type_ids` (all int64), output is
  /// `last_hidden_state` [batch, seq, 384] — token level, so the app
  /// mean-pools and L2-normalises. `vocab.txt` is not optional: without it the
  /// service falls back to a hash tokenizer and retrieval quality collapses.
  static const LocalModel miniLm6 = LocalModel(
    id: 'all-minilm-l6-v2',
    displayName: 'all-MiniLM-L6-v2 (embeddings)',
    description: 'Powers Memory search. Required for RAG.',
    kind: ModelKind.embedding,
    fileName: 'minilm-l6-v2.onnx',
    url: 'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx',
    approxBytes: 91000000,
    minBytes: 20 * 1024 * 1024,
    extraFiles: [
      (
        name: 'vocab.txt',
        url: 'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/vocab.txt',
        minBytes: 100 * 1024,
      ),
    ],
    ramHint: '~120 MB',
  );

  /// Models the user can pick as the chat brain.
  static const List<LocalModel> llms = [qwen05b, smolLm2_360m, qwen15b];

  /// Models the user can pick for image understanding.
  static const List<LocalModel> visionModels = [moondream2];

  /// Models the user can pick for memory/retrieval.
  static const List<LocalModel> embeddingModels = [miniLm6];

  static const List<LocalModel> all = [
    qwen05b,
    smolLm2_360m,
    qwen15b,
    moondream2,
    miniLm6,
  ];

  static LocalModel? byId(String? id) {
    if (id == null) return null;
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Default chat model (smallest that still does tool calls well).
  static const LocalModel defaultLlm = qwen05b;

  /// Whether this build can actually serve [m]. Kept as a function rather
  /// than hardcoded so a binding swap that drops mtmd can disable vision here
  /// instead of letting the user download 1.3 GB that never loads.
  static bool isUsable(LocalModel m) => true;

  /// Deliberately unsupported, documented so the UI can explain why.
  static const String needleNote =
      'Needle (Cactus) is not GGUF — it needs the Cactus native runtime, '
      'so it cannot be loaded through llama.cpp.';
}
