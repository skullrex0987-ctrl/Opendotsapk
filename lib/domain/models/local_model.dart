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

  /// Non-null when this build genuinely cannot serve the model — for example
  /// when the vendored llama.cpp has no vision encoder for its projector.
  /// The UI greys the row out and says why, instead of letting the user
  /// download gigabytes that are guaranteed never to load.
  final String? unsupportedReason;

  /// The llama.cpp architecture name (e.g. `qwen2`, `phi2`, `qwen35`).
  /// Used to validate LLM–vision projector pairing before load.
  /// Null for embedding models and models whose arch is unknown.
  final String? llmArch;

  /// True for multimodal models (e.g. Qwen3.5) that carry both chat and
  /// vision in a single GGUF. They appear in both the LLM and Vision lists
  /// so the user can select them as either or both — selecting as both is
  /// the correct pairing because the same file is the LLM and the projector.
  final bool isMultimodal;

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
    this.unsupportedReason,
    this.llmArch,
    this.isMultimodal = false,
  });

  bool get isVision => kind == ModelKind.vision || isMultimodal;
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
    llmArch: 'qwen2',
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
    llmArch: 'phi2',
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
    llmArch: 'qwen2',
  );

  // ---------------------------------------------------------- vision models
  //
  // Qwen3.5 has vision **built in**. One GGUF carries the language model and
  // its ViT, and the matching `mmproj` supplies the merger — it is not a text
  // brain with a projector bolted onto the side. The vendored llama.cpp
  // registers its arch as `qwen35` and its encoder as `qwen3vl_merger`, both
  // of which are present in this build.
  //
  // Size/hash pins were read from the Hugging Face tree API (the LFS `oid` is
  // the SHA-256), not typed by hand.
  static const LocalModel qwen35_08b = LocalModel(
    id: 'qwen3.5-0.8b-q4_k_m',
    displayName: 'Qwen3.5 0.8B (vision)',
    description: 'Sees images natively and chats. One download, no separate projector to manage.',
    kind: ModelKind.vision, // also appears in llms list via isMultimodal
    fileName: 'Qwen3.5-0.8B-Q4_K_M.gguf',
    url: 'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf',
    // 532,517,120 B weights + 204,987,232 B mmproj = 737,504,352 B.
    approxBytes: 737504352,
    projectorFileName: 'mmproj-F16.gguf',
    projectorUrl: 'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/mmproj-F16.gguf',
    contextSize: 4096,
    ramHint: '~1.1 GB',
    llmArch: 'qwen35',
    isMultimodal: true, // also appears in the LLM list
  );

  static const LocalModel moondream2 = LocalModel(
    id: 'moondream2-q5k',
    displayName: 'Moondream2',
    description: 'Image understanding with a separate CLIP projector.',
    kind: ModelKind.vision,
    fileName: 'moondream2-050824-q5k.gguf',
    url: 'https://huggingface.co/cjpais/moondream2-llamafile/resolve/main/moondream2-050824-q5k.gguf',
    // Weights 1,059,610,016 B + mmproj 909,777,984 B = 1,969,388,000 B.
    approxBytes: 1969388000,
    projectorFileName: 'moondream2-mmproj-050824-f16.gguf',
    projectorUrl: 'https://huggingface.co/cjpais/moondream2-llamafile/resolve/main/moondream2-mmproj-050824-f16.gguf',
    contextSize: 2048,
    ramHint: '~2.4 GB',
  );

  /// Small, efficient vision model (0.4B params). Q4_K_M quantisation keeps it
  /// under 300 MB with a ~200 MB projector, making it the lightest vision
  /// option in the catalogue.
  static const LocalModel smolVlm500m = LocalModel(
    id: 'smolvlm-500m-instruct-q4_k_m',
    displayName: 'SmolVLM 500M Instruct',
    description:
        'Smallest vision model. Great for quick image Q&A on any phone.',
    kind: ModelKind.vision,
    fileName: 'SmolVLM-500M-Instruct-Q4_K_M.gguf',
    url: 'https://huggingface.co/pierretokns/SmolVLM-500M-Instruct-GGUF/resolve/main/SmolVLM-500M-Instruct-Q4_K_M.gguf',
    // 303,251,712 B weights + 199,468,864 B projector = 502,720,576 B.
    approxBytes: 502720576,
    projectorFileName: 'mmproj-SmolVLM-500M-Instruct-f16.gguf',
    projectorUrl: 'https://huggingface.co/pierretokns/SmolVLM-500M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-500M-Instruct-f16.gguf',
    contextSize: 2048,
    ramHint: '~800 MB',
    llmArch: 'llama',
  );

  /// InternVL2.5-1B: good vision quality at a small footprint (0.6B params).
  /// Q4_K_M gives ~470 MB weights plus a ~620 MB projector.
  static const LocalModel internVl2_5_1b = LocalModel(
    id: 'internvl2_5-1b-q4_k_m',
    displayName: 'InternVL2.5 1B',
    description:
        'Solid vision quality, still small enough for mid-range phones.',
    kind: ModelKind.vision,
    fileName: 'InternVL2_5-1B.Q4_K_M.gguf',
    url: 'https://huggingface.co/mradermacher/InternVL2_5-1B-GGUF/resolve/main/InternVL2_5-1B.Q4_K_M.gguf',
    // 490,984,416 B weights + 619,876,960 B projector = 1,110,861,376 B.
    approxBytes: 1110861376,
    projectorFileName: 'InternVL2_5-1B.mmproj-f16.gguf',
    projectorUrl: 'https://huggingface.co/mradermacher/InternVL2_5-1B-GGUF/resolve/main/InternVL2_5-1B.mmproj-f16.gguf',
    contextSize: 4096,
    ramHint: '~1.5 GB',
    llmArch: 'qwen2',
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
  ///
  /// Qwen3.5 is included here because it is a multimodal model — the same GGUF
  /// serves as both LLM and vision backbone, so users should be able to pick it
  /// as their chat model when they want vision support.
  static const List<LocalModel> llms = [
    qwen05b,
    smolLm2_360m,
    qwen15b,
    qwen35_08b,
    smolVlm500m,
    internVl2_5_1b,
  ];

  /// Models the user can pick for image understanding.
  static const List<LocalModel> visionModels = [
    qwen35_08b,
    smolVlm500m,
    internVl2_5_1b,
  ];

  /// Models the user can pick for memory/retrieval.
  static const List<LocalModel> embeddingModels = [miniLm6];

  static const List<LocalModel> all = [
    qwen05b,
    smolLm2_360m,
    qwen15b,
    qwen35_08b,
    smolVlm500m,
    internVl2_5_1b,
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

  /// Whether this build can actually serve [m].
  ///
  /// Driven by [LocalModel.unsupportedReason] so a model whose runtime support
  /// is missing is greyed out and explained, rather than letting the user
  /// download gigabytes that can never load.
  static bool isUsable(LocalModel m) => m.unsupportedReason == null;

  /// Whether [m] may be used as the **chat** brain.
  ///
  /// A plain LLM, or a multimodal model whose single GGUF carries the language
  /// model too (Qwen3.5 is registered with [ModelKind.vision] because vision is
  /// why it is listed at all — but it is equally a chat model). Checking only
  /// `kind == ModelKind.llm` is what made selecting Qwen3.5 as the chat model
  /// silently fall back to an undownloaded default, so the Load button did
  /// nothing. Kept here, on the pure model layer, so it is unit-testable
  /// without SharedPreferences or a device.
  static bool isChatCapable(LocalModel m) =>
      m.kind == ModelKind.llm || m.isMultimodal;

  /// The vision model a fresh install should pick.
  static const LocalModel defaultVision = qwen35_08b;

  /// Deliberately unsupported, documented so the UI can explain why.
  static const String needleNote =
      'Needle (Cactus) is not GGUF — it needs the Cactus native runtime, '
      'so it cannot be loaded through llama.cpp.';
}
