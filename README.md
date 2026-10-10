# LocalMind

A fully local, privacy-first AI agent for Android that runs entirely on-device.

**Download the APK:** [Releases → v1.0.0](https://github.com/skullrex0987-ctrl/Opendotsapk/releases/tag/v1.0.0)

## Status

| Area | State |
|---|---|
| Local LLM inference (llama.cpp) | Working — `libllama.so` + `libggml*.so` verified in the APK |
| Embeddings / RAG (ONNX Runtime) | Working — `libonnxruntime.so` verified |
| Model chooser + in-app downloader | Working |
| 9 Android tools + permissions | Working |
| Multi-agent (Planner/Executor/Critic) | Working |
| Voice in/out | Working |
| Vision (Moondream2) | Working — full mtmd API verified in `libnative_llama.so` (statically linked, not a separate `.so`) |

## Features

- **Local LLM Inference**: llama.cpp via FFI running quantized GGUF models, CPU backend
- **Selectable models**: the app downloads the model you pick at runtime, nothing bundled
- **Multi-Agent System**: Planner → Executor → Critic pipeline for task decomposition
- **Tool Calling**: JSON-based function calling with an Allow/Ask/Block permission system
- **On-Device Actions**: SMS, Calendar, Contacts, Alarms, Web Search, Location, Notes
- **RAG Memory**: local vector store for conversation history and user facts
- **Voice Input/Output**: speech-to-text and text-to-speech
- **Privacy-First**: no data leaves the device (except optional web search)

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

1. **First Launch**: You'll see a welcome screen prompting you to download/load a model
2. **Model Selection**: Go to Settings → Model Management to select your GGUF file
3. **Start Chatting**: Type or speak your request
4. **Tool Permissions**: Set permissions for each tool in Settings
5. **View Activity**: Check the Activity tab to see all tool executions
6. **Manage Memories**: View and edit stored memories in the Memory tab

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
├── main.dart                    # App entry point
├── app.dart                     # Root widget + theme
├── core/
│   └── constants/
│       └── app_constants.dart   # Constants, prompts, permissions
├── data/
│   ├── database/
│   │   └── database_helper.dart # SQLite + sqlite-vec
│   ├── services/
│   │   ├── llm_service.dart        # llama.cpp wrapper
│   │   ├── embedding_service.dart  # ONNX embeddings (MiniLM)
│   │   └── model_manager.dart      # Model download / select / delete
│   └── tools/
│       └── tool_registry.dart   # Tool definitions + execution
├── domain/
│   ├── agents/
│   │   └── agent_orchestrator.dart # Multi-agent pipeline
│   └── models/
│       ├── models.dart          # Chat/plan/tool data models
│       └── local_model.dart     # Selectable model catalog
└── presentation/
    ├── screens/
    │   ├── main_screen.dart     # Bottom nav
    │   ├── chat_screen.dart     # Chat interface
    │   ├── memory_screen.dart   # Memory management
    │   ├── models_screen.dart   # Model chooser + downloader
    │   ├── activity_screen.dart # Activity log
    │   └── settings_screen.dart # Settings
    ├── providers/
    │   └── providers.dart       # Riverpod providers
    └── widgets/
        └── message_bubble.dart  # Message UI
```

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
