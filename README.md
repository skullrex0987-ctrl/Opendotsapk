<div align="center">

<img src="docs/logo.svg" alt="LocalMind" width="128" height="128">

# LocalMind

**Privacy-first, fully local AI agent for Android.** 

Inference, retrieval, and documents stay entirely on your device. Powered by `llama.cpp`, LocalMind brings high-performance LLMs to your pocket without the cloud.

[![Build APK](https://github.com/skullrex0987-ctrl/Opendotsapk/actions/workflows/build-apk.yml/badge.svg)](https://github.com/skullrex0987-ctrl/Opendotsapk/actions/workflows/build-apk.yml)
[![Release](https://img.shields.io/github/v/release/skullrex0987-ctrl/Opendotsapk?style=flat&color=6366F1&logo=github)](https://github.com/skullrex0987-ctrl/Opendotsapk/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-6366F1?style=flat)](./LICENSE)
[![Platform](https://img.shields.io/badge/Android-9%2B-34D399?logo=android&logoColor=white)](https://developer.android.com/guide/topics/manifest/uses-sdk-element)
[![Runtime](https://img.shields.io/badge/Runtime-llama.cpp-22D3EE?logo=cplusplus&logoColor=white)](https://github.com/ggerganov/llama.cpp)

[**⬇ Download Latest APK**](https://github.com/skullrex0987-ctrl/Opendotsapk/releases/latest) &nbsp;·&nbsp;
[Model Support](docs/MODEL_SUPPORT.md) &nbsp;·&nbsp;
[Release Notes](docs/RELEASE_v1.6.0.md) &nbsp;·&nbsp;
[FAQ](docs/FAQ.md)

</div>

---

## 🌟 Key Features

LocalMind is designed for speed, privacy, and flexibility.

| | Feature | Description |
|---|---|---|
| 🔒 | **100% Offline** | No account, no telemetry, and no server. Your data never leaves the device. |
| 🚀 | **Vulkan GPU Acceleration** | Native GPU offloading for snappy responses on modern Android hardware. |
| 🧠 | **On-Device RAG** | Vector search and hybrid retrieval for your local PDFs, DOCX, and EPUBs. |
| 👁️ | **Vision Support** | Understand images locally using multimodal models like Qwen3.5. |
| 🔑 | **Secure Storage** | API keys and sensitive data stay in the Android Keystore, encrypted at rest. |
| 🎙️ | **Voice Integration** | Native Speech-to-Text and Text-to-Speech for hands-free interaction. |
| ☁️ | **Optional Cloud (BYOK)** | Bring your own keys for OpenAI, Anthropic, Gemini, Groq, and more. |

---

## 🚀 What's New in v1.6.0

This release focuses on **multimodal stability**, **UI/UX refinements**, and **performance optimizations**.

- **✨ Qwen3.5 Multimodal Fix:** Fully supported as both a chat and vision model. No more silent fallbacks.
- **🎨 Unified Design Language:** A complete UI pass for consistent themes, curves, and motion across all 11 screens.
- **⚡ Faster Model Discovery:** Optimized disk I/O with memoised directory lookups and smart TTL caching.
- **🐛 Critical Bug Fixes:** Resolved staggered list entrance crashes and incorrect architecture warnings.
- **🔇 Enhanced Logging:** Better diagnostics for silent failures in background tasks and secure storage.

[**Read the full v1.6.0 Release Notes →**](docs/RELEASE_v1.6.0.md)

---

## 📸 Screenshots

<div align="center">
  <p><i>Visualizing the next generation of local AI.</i></p>
  <img src="docs/screenshots/chat.png" alt="Chat UI" width="200" onerror="this.onerror=null;this.src='https://placehold.co/400x800?text=Chat+Interface';">
  <img src="docs/screenshots/models.png" alt="Models UI" width="200" onerror="this.onerror=null;this.src='https://placehold.co/400x800?text=Model+Catalog';">
  <img src="docs/screenshots/settings.png" alt="Settings UI" width="200" onerror="this.onerror=null;this.src='https://placehold.co/400x800?text=Settings';">
</div>

> **📸 Adding real screenshots:** Drop `chat.png`, `models.png`, and `settings.png` into [`docs/screenshots/`](docs/screenshots/) and they will automatically replace the placeholders above. Until then, placeholders are shown.

---

## 🛠️ Quick Start

### 1. Installation
1. Download the latest APK from the [Releases](https://github.com/skullrex0987-ctrl/Opendotsapk/releases/latest) page.
2. Install it on your Android 9+ device (arm64-v8a required).
3. Enable "Install from unknown sources" if prompted.

### 2. Setting Up Models
1. Open the app and head to **Settings → Models**.
2. Pick a model (e.g., **Qwen2.5 0.5B** for speed or **Qwen3.5 0.8B** for vision).
3. Wait for the download to complete (resumable if interrupted).
4. Tap **Load** and start chatting!

---

## 🏗️ Architecture & Development

LocalMind is built with a clean, decoupled architecture:
- **Presentation:** Flutter + Riverpod for reactive UI and state management.
- **Domain:** Pure Dart logic for model catalogs and agent orchestration (fully testable).
- **Data:** Native bindings for `llama.cpp`, `ONNX Runtime`, and `SQLite` (Vector).

### Local Build
Requires Flutter 3.47.7+, Android SDK 36, and `glslc` for Vulkan support.

```bash
# Install Vulkan shader compiler
sudo apt-get install -y glslc spirv-tools libvulkan-dev

# Get dependencies and patch native bindings
flutter pub get
python3 scripts/patch_native_llama.py

# Build the APK
flutter build apk --release --target-platform android-arm64
```

For more build options and CI details, see [BUILD_OPTIONS.md](BUILD_OPTIONS.md).

---

## 📄 License & Credits

- **License:** [MIT](./LICENSE)
- **Engine:** [llama.cpp](https://github.com/ggerganov/llama.cpp)
- **Models:** [Qwen](https://github.com/QwenLM/Qwen) & [SmolLM](https://huggingface.co/HuggingFaceTB)
- **Embeddings:** [sentence-transformers](https://huggingface.co/sentence-transformers)

---
<div align="center">
  Built with ❤️ for Privacy and Open Source.
</div>
