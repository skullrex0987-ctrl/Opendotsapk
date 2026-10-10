# LocalMind

A fully local, privacy-first AI agent for Android that runs entirely on-device.

## Features

- **Local LLM Inference**: Uses llama.cpp via FFI to run quantized GGUF models
- **Multi-Agent System**: Planner → Executor → Critic pipeline for task decomposition
- **Tool Calling**: JSON-based function calling with permission system
- **On-Device Actions**: SMS, Calendar, Contacts, Alarms, Web Search, Notes, etc.
- **RAG Memory**: Local vector database for conversation history and context
- **Voice Input/Output**: Speech-to-text and text-to-speech support
- **Background Tasks**: Scheduled jobs and foreground services
- **Privacy-First**: No data leaves your device (except optional web search)

## Requirements

- Flutter 3.x
- Android SDK 26+ (Android 8.0)
- Target SDK 34
- At least 6GB RAM device recommended
- GGUF model file (~1GB for 1.5B Q4 model)

## Setup

### 1. Install Flutter

```bash
# If not already installed
git clone https://github.com/flutter/flutter.git ~/flutter
export PATH="$PATH:$HOME/flutter/bin"
flutter doctor
```

### 2. Clone and Setup

```bash
git clone <repository-url>
cd localmind
flutter pub get
```

### 3. Download Model

```bash
# Using the provided script
chmod +x download_model.sh
./download_model.sh

# Or manually download Qwen2.5-1.5B-Instruct-Q4_K_M
mkdir -p assets/models
curl -L -o assets/models/model.gguf "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
```

### 4. Build

```bash
# Debug build
flutter build apk --debug

# Release build
flutter build apk --release
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
├── core/
│   └── constants/
│       └── app_constants.dart   # Constants and config
├── data/
│   ├── database/
│   │   └── database_helper.dart # SQLite operations
│   ├── services/
│   │   ├── llm_service.dart     # llama.cpp wrapper
│   │   └── embedding_service.dart # ONNX embeddings
│   └── tools/
│       └── tool_registry.dart   # Tool definitions
├── domain/
│   ├── agents/
│   │   └── agent_orchestrator.dart # Multi-agent pipeline
│   └── models/
│       └── models.dart          # Data models
└── presentation/
    ├── screens/
    │   ├── main_screen.dart     # Bottom nav
    │   ├── chat_screen.dart     # Chat interface
    │   ├── memory_screen.dart   # Memory management
    │   ├── activity_screen.dart # Activity log
    │   └── settings_screen.dart # Settings
    ├── providers/
    │   └── providers.dart       # Riverpod providers
    └── widgets/
        └── message_bubble.dart  # Message UI
```

## Troubleshooting

### Model won't load
- Ensure you're using a valid GGUF file
- Check that the file is in the assets/models directory
- Try a smaller model (700MB+) for devices with less RAM

### Performance issues
- Use Q4_K_M quantization for best speed/memory balance
- Reduce context size in Settings if needed
- Close other apps to free RAM

### Permission denied errors
- Grant permissions in Settings → Tool Permissions
- Some tools require Android runtime permissions

## License

MIT License - See LICENSE file for details

## Acknowledgments

- [llama.cpp](https://github.com/ggerganov/llama.cpp) for efficient LLM inference
- [TigerVNC](https://tigervnc.org/) for VNC implementation
- [Qwen](https://github.com/QwenLM/Qwen) for the base model
- [MiniLM](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) for embeddings
