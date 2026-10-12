# Release Notes: v1.6.0 (Stabilization & UI)

This release marks a significant milestone in **multimodal stability** and **visual consistency**. We've resolved the critical "Qwen3.5 load failure" that affected vision capabilities and unified the entire application under a single, professional design system.

---

## 🚀 New Features

### 🎨 Design Foundation: `AppTheme` & `AppMotion`
The app is no longer a collection of independently styled screens. We have introduced a centralized design system:
- **Unified Theme:** A consistent brand palette (Indigo `#6366F1`) and cyan accent (`#22D3EE`) for AI interactions.
- **Stepped Surfaces:** Improved dark mode readability with clear background/surface elevation hierarchy.
- **Motion Language:** Standardized curves and timings (120ms to 450ms steps) for a premium feel.
- **Staggered Entrances:** Activity, Memory, and Cloud sections now animate gracefully instead of popping into view.

### ⚡ Model List Performance
Browsing models is now instantaneous:
- **Directory Memoisation:** Disk path resolution is performed once per process.
- **Smart TTL Caching:** `FilePresenceCache` reduces disk I/O, invalidated only when files are modified.
- **Optimized Probing:** Reduced platform-channel overhead for checking installed models.

---

## 🐛 Bug Fixes

### 👁️ Qwen3.5 Multimodal Fix
Fixed a critical bug where Qwen3.5 (Multimodal) could not be loaded as a chat model. 
- **Cause:** The app strictly required `ModelKind.llm`, but Qwen3.5 was registered as `ModelKind.vision`.
- **Fix:** Introduced `isChatCapable` logic that recognizes multimodal models as valid chat brains.
- **Verification:** Unit tests now confirm Qwen3.5 appears in both the chat and vision selection lists.

### 📉 Staggered Entrance Crash
Resolved a "Failed assertion: begin <= 1.0" crash that prevented screens from opening on many devices.
- **Cause:** Incorrect arithmetic in animation delay clamping.
- **Fix:** Corrected the ratio calculation to ensure animation intervals always stay within valid bounds (0.0 to 1.0).

### 🛠️ Architecture Warning Fix
The architecture mismatch warning ("Model A cannot use Model B") now correctly names the selected chat model instead of defaulting to a cached label.

### 🔍 Undownloaded Model Detection
Fixed a logic error where missing models were incorrectly reported as "installed with -1 bytes." 
- **Fix:** Now explicitly checks `FileSystemEntityType.notFound` returned by the file system.

### 🔇 Silent Failures Exposed
Six major "silent `catch` blocks" have been removed or updated to log errors properly. 
- **Impact:** Failures in download cleanups, connectivity probes, and secure storage reads are now visible in **Activity → Diagnostics**.

---

## 🏗️ Internal Changes

- **Test Suite Expansion:** Added 14 new unit and widget tests covering chat selection logic, motion math, and file cache correctness.
- **Native Logging:** Improved `LlmService` to capture and surface real native error messages from `llama.cpp` directly in the UI.
- **Graceful GPU Fallback:** If Vulkan GPU initialization fails, the app now automatically retries on the CPU instead of hanging.

---

## 📋 Known Issues & Next Steps

- **Agent Integration:** `AgentOrchestrator` is ready but not yet wired into the main chat UI.
- **Tool System:** Seven tool definitions are scaffolded but pending system Intent implementations.
- **Background Downloads:** Downloads may still pause if the app is minimized for long periods (Foreground Service planned for v1.7.0).

---

## 🛠️ Verification
All changes in this release have passed the following gates:
- [x] **244 Unit & Widget Tests** (`flutter test`)
- [x] **Native Library Presence** (libllama, libggml, libonnxruntime)
- [x] **ELF 16 KB Page Alignment Check**
- [x] **Version/Tag Equality Assertion**

---
*Note: This release is debug-signed. For production-ready updates, please follow the [Release Signing Guide](RELEASE_SIGNING.md).*
