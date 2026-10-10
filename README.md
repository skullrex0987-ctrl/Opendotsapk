# LocalMind

A fully local, privacy-first AI agent for Android that runs entirely on-device.

**Download the APK:** [Releases → v1.1.0](https://github.com/skullrex0987-ctrl/Opendotsapk/releases/tag/v1.1.0)

## Status

| Area | State |
|---|---|
| Local LLM inference (llama.cpp) | Working — `libllama.so` + `libggml*.so` verified in the APK |
| Embeddings / RAG (ONNX Runtime) | Working — `libonnxruntime.so` verified |
| Model chooser + in-app downloader | Working |
| 9 Android tools + permissions | Working |
| Multi-agent (Planner/Executor/Critic) | Working |
| Voice in/out | Working |
| Vision (Moondream2) | Working — mtmd statically linked in `libnative_llama.so` (189 symbols), reachable from the composer |
| Cloud models (BYOK) | Working — 12 providers, keys in the hardware keystore |
| Local/cloud router | Working — on-device by default, rule-based escalation |
| MCP client | Working — streamable HTTP, tools join the agent's tool set |
| Hybrid retrieval + reranking | Working — dense + BM25, MMR reranking |
| Document ingestion | Working — PDF, DOCX, plain text |
| At-rest encryption + biometric lock | Working — AES-GCM, key in the keystore |
| GPU / NPU acceleration | **Not enabled** — Vulkan source is vendored but needs `glslc`; see `docs/GPU_ACCELERATION.md` |
| Verified on a physical device | **No** — compiles and tests pass; never launched on hardware |

## Features

- **Local LLM Inference**: llama.cpp via FFI running quantized GGUF models, CPU backend
- **Selectable models**: the app downloads the model you pick at runtime, nothing bundled
- **Multi-Agent System**: Planner → Executor → Critic pipeline for task decomposition
- **Tool Calling**: JSON-based function calling with an Allow/Ask/Block permission system
- **On-Device Actions**: SMS, Calendar, Contacts, Alarms, Web Search, Location, Notes
- **Vision**: attach an image from the camera or gallery and a vision model describes it
- **Cloud models, your key**: OpenAI, Anthropic, Google, Groq, OpenRouter, Mistral, xAI,
  DeepSeek, Together, Fireworks, Ollama, or any OpenAI-compatible endpoint. The key is
  written to the Android Keystore and read only when a request is about to be made.
  There is no LocalMind server.
- **A router, not a switch**: short and personal turns stay on-device; long or code-heavy
  ones go to the cloud when a key exists. Private mode forbids network use entirely.
- **MCP client**: connect Model Context Protocol servers over streamable HTTP and their
  tools become available to the agent
- **RAG Memory**: hybrid dense + BM25 search with MMR reranking over conversation history,
  notes, and ingested documents
- **Document ingestion**: pick a PDF, DOCX, or text file; it is chunked, embedded, and
  searchable
- **Voice Input/Output**: speech-to-text and text-to-speech
- **Security**: messages and memories encrypted at rest, optional biometric lock,
  per-tool permissions enforced in the agent loop
- **Privacy-First**: nothing leaves the device unless you add a cloud key or enable
  web search

## Model catalog

Pick one in **Settings → Models**; the app downloads it with live progress.

| Model | Size | RAM | Notes |
|---|---|---|---|
| Qwen2.5-0.5B-Instruct Q4_K_M | ~397 MB | ~600 MB | default, good tool-calling |
| SmolLM2-360M-Instruct Q8_0 | ~386 MB | ~550 MB | fastest |
| Qwen2.5-1.5B-Instruct Q4_K_M | ~1.12 GB | ~1.4 GB | best quality |
| Moondream2 q5_k + mmproj | ~1.6 GB | ~1.6 GB | image understanding |

> **Needle (Cactus) is not supported.** It ships as `.cact` + `.safetensors` with its own
> native runtime (`libneedle.a`), not GGUF, so it cannot be loaded through llama.cpp.

## Requirements

- Flutter **3.47.7** (pinned in CI; `llama_cpp_dart` needs Dart ≥ 3.7)
- Android SDK 35 / NDK 28.2, Gradle 8.14.3, AGP 8.11.1, Kotlin 2.2.20
- **minSdk 28**, targetSdk 35, **arm64-v8a only**
  (native_llama needs `SharedMemory`, API 27+; llama.cpp is built for arm64)

## Build

The authoritative build is GitHub Actions — every push to `main` builds the APK and
verifies the native libraries are actually inside it:

```bash
flutter pub get
python3 scripts/patch_native_llama.py   # disables Vulkan; see the script's docstring
flutter build apk --release --target-platform android-arm64
```

Local build without the patch step will fail at link time with
`undefined symbol: ggml_backend_vk_reg`.

### Download models for local testing

```bash
./download_model.sh list      # show the catalog
./download_model.sh qwen05b   # or smollm2 | qwen15b | moondream2 | all
```

## Usage

1. **First launch**: three screens explain what the app does and where your data
   goes, then you pick a model
2. **Model selection**: download a GGUF from the catalog, or load one from storage
3. **Start chatting**: type, speak, or attach an image or document
4. **Cloud (optional)**: Settings → Cloud Models → pick a provider → paste your own
   key. "Test connection" confirms it works. Routing defaults to Auto: on-device
   for short and personal turns, cloud for long or code-heavy ones.
5. **Private mode**: forbids all network use, whatever else is configured
6. **Tool permissions**: Allow / Ask / Block per tool, in the Tools tab
7. **MCP**: Tools → MCP servers → add a streamable HTTP endpoint and its tools join
   the agent's tool set
8. **Activity**: every tool execution is logged in the Activity tab
9. **Memories**: view and edit stored memories in the Memory tab

### Enabling cloud models

Nothing is sent anywhere until you add a key. Keys are stored in the Android
Keystore and read only at the moment a request is made. The app has no backend;
your key goes straight from your phone to the provider you chose.

If the provider is OpenAI-compatible (Groq, OpenRouter, Together, Fireworks,
Ollama, LM Studio, vLLM, or anything self-hosted), choose **Custom** and set the
base URL. For a server on your LAN, the URL must be reachable from the phone.

## Tools

| Tool | Description | Permission |
|------|-------------|------------|
| send_sms | Send SMS messages | Ask |
| create_calendar_event | Add calendar events | Ask |
| add_contact | Add new contacts | Ask |
| set_alarm | Set alarms | Ask |
| open_app | Open apps by package name | Ask |
| web_search | Search DuckDuckGo | Allow |
| get_location | Get current location | Ask |
| create_note | Create notes | Allow |
| read_notes | Search notes | Allow |

## Architecture

```
lib/
├── main.dart                    # Entry: keystore, crypto, connectivity, WorkManager
├── app.dart                     # Root widget, theme, splash, biometric gate
├── core/
│   ├── constants/
│   │   └── app_constants.dart   # Constants, prompts, permissions
│   ├── security/
│   │   └── crypto_box.dart      # AES-GCM at-rest field encryption
│   └── utils/
│       ├── log.dart             # Bounded in-memory ring logger
│       └── text_utils.dart      # Chunking, BM25, MMR, truncation
├── data/
│   ├── database/
│   │   └── database_helper.dart # SQLite + vectors, hybrid search + reranking
│   ├── services/
│   │   ├── llm_service.dart        # llama.cpp wrapper
│   │   ├── embedding_service.dart  # ONNX embeddings (MiniLM)
│   │   ├── model_manager.dart      # Model download / select / delete
│   │   ├── cloud_service.dart      # BYOK clients, one per wire format
│   │   ├── router_service.dart     # Local vs cloud decisions
│   │   ├── mcp_service.dart        # Model Context Protocol client
│   │   ├── document_service.dart   # PDF / DOCX / OCR ingestion
│   │   └── secure_store.dart       # Keystore-backed secret storage
│   └── tools/
│       └── tool_registry.dart   # Tool definitions + execution
├── domain/
│   ├── agents/
│   │   └── agent_orchestrator.dart # Multi-agent pipeline
│   └── models/
│       ├── models.dart          # Chat/plan/tool data models
│       ├── local_model.dart     # Selectable model catalog
│       └── cloud_provider.dart  # Cloud provider catalog
└── presentation/
    ├── screens/
    │   ├── main_screen.dart     # Bottom nav
    │   ├── chat_screen.dart     # Chat, image/doc attachment, route badge
    │   ├── memory_screen.dart   # Memory management
    │   ├── models_screen.dart   # Model chooser + downloader
    │   ├── cloud_screen.dart    # Cloud providers + routing
    │   ├── tools_screen.dart    # Tool permissions + MCP servers
    │   ├── onboarding_screen.dart # First run
    │   ├── activity_screen.dart # Activity log
    │   └── settings_screen.dart # Settings
    ├── providers/
    │   └── providers.dart       # Riverpod providers
    └── widgets/
        ├── message_bubble.dart  # Message UI
        └── biometric_gate.dart  # Optional app lock
```

## Tests

```bash
flutter test
```

113 tests covering text chunking and BM25 scoring, AES-GCM and codec round-trips,
the routing rules, hybrid retrieval and MMR, and document parsing. CI runs this as
a hard gate — the APK is not built if a test fails.

## Troubleshooting

### Model won't load
- Download it from **Settings → Models** first; the app stores models in its
  documents directory, not in `assets/`
- Ensure it is a valid GGUF and the download completed (not a `.part` file)
- Try the smaller SmolLM2-360M for low-RAM devices

### `undefined symbol: ggml_backend_vk_reg` when building
Run `python3 scripts/patch_native_llama.py` after `flutter pub get`. The
`native_llama` package forces Vulkan on but vendors a ggml-cpu without the
required kernels.

### `libllama.so missing` in the APK
The build is arm64-only on purpose. Building for other ABIs produces jars that
can never load a model — keep `--target-platform android-arm64`.

### Performance issues
- Use Q4_K_M quantization for the best speed/memory balance
- Lower the context size in Settings
- Close other apps to free RAM

### Permission denied errors
- Grant permissions in Settings → Tool Permissions
- Some tools also need Android runtime permissions

## License

MIT License - See LICENSE file for details

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) for efficient LLM inference
- [native_llama](https://pub.dev/packages/native_llama) for the Flutter FFI bindings
- [Qwen](https://github.com/QwenLM/Qwen) and [SmolLM2](https://huggingface.co/HuggingFaceTB) for the base models
- [MiniLM](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) for embeddings
