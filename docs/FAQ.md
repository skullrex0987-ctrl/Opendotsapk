# FAQ

Short answers. Anything longer belongs in [README.md](../README.md) or one of the
documents in this folder.

## Privacy

**Does anything leave the phone?**
Not unless you ask it to. Inference, embeddings, retrieval, document parsing and
the tool permission system are entirely on-device. The only network paths are a
cloud provider you configure yourself and the `web_search` tool.

**Do I need an account?**
No. There is no LocalMind server, no sign-up and no shared quota.

**Is there telemetry?**
None. The app makes no analytics call of any kind.

**Where are my cloud API keys?**
In the Android Keystore, written through `flutter_secure_storage` and read at the
moment a request is about to be made. They are never written to
`shared_preferences` or into a database row.

**What if the Keystore is unavailable?**
The app logs `keystore unavailable — running without at-rest encryption` and
continues in plaintext. Losing access to your own notes would be worse than the
protection it buys, and the log says exactly what happened so the state is never
silent.

**How strong is the at-rest encryption?**
AES-GCM per field, over messages, memories, notes, chunks and activity logs, with
the key in the Keystore. It is deliberately not full-database SQLCipher: that
would pull a second SQLite into an APK that already ships three native runtimes,
for a threat model it does not actually cover. It protects against a stolen,
unrooted phone or an extracted backup. It does not hide data from a rooted device
or from you — the model runs in-process and needs plaintext to answer.

**What does private mode do?**
It forbids network use absolutely, including the startup connectivity probe that
would otherwise run before you had chosen anything. See `B5` in
[AUDIT_PROGRESS.md](AUDIT_PROGRESS.md).

## Models

**Which model should I pick?**
Qwen2.5 0.5B for the smallest download and solid tool calls. SmolLM2 360M if
speed or RAM matters most. Qwen2.5 1.5B for the best answers and a phone that can
keep up. Qwen3.5 0.8B if you want vision too — one download does both.

**Why is Moondream2 greyed out?**
Because it can never load. The vendored llama.cpp identifies a vision projector by
a member of the `projector_type` enum in `tools/mtmd/clip-impl.h`; that enum has
42 members and none of them is Moondream, so the projector parses as unknown and
`initVision` fails on every device. Re-downloading cannot fix it. It stays listed
so anyone holding 1.97 GB gets an explanation. Evidence in
[MODEL_SUPPORT.md](MODEL_SUPPORT.md).

**Can I load a GGUF from storage instead?**
Yes — the model sheet has "Load from Storage".

**Why is nothing bundled in the APK?**
So you choose the size/quality trade-off, and the APK stays small. The cost is a
one-time download per model.

**Do downloads resume?**
Yes. A partial transfer keeps its `.part` file and resumes with an HTTP `Range`;
a file is promoted into place only when its size and SHA-256 both match the
pinned manifest. They still stop if Android suspends the app — there is no
foreground service yet.

## Speed and the GPU

**Is the GPU faster?**
Sometimes. Token generation is memory-bandwidth-bound, and on many midrange Mali
parts well-vectorised NEON kernels win. Settings → Performance runs a benchmark
on your own hardware — believe the numbers, not the marketing.

**What does Auto pick?**
CPU for midrange Mali, for `isLowRamDevice`, for anything under 4 GB of RAM, and
for emulators; GPU on other known hardware with enough RAM; and for unrecognised
hardware it tries the GPU and falls back if the driver refuses.

**Why does the NPU sit there unused?**
Because there is nothing portable to call. Every phone NPU needs a vendor runtime
— QNN/Hexagon, NeuroPilot, ENN, Edge TPU, Da Vinci — with no common build
target, and llama.cpp has no portable NPU backend. The app detects and names the
NPU rather than pretending.

**Can I reduce memory use?**
A smaller model, a smaller context window in Settings, and closing other apps.
Under 4 GB of RAM, Auto forces the CPU: that is when GPU buffers alongside the
model get the app killed.

## Build and install

**Which devices?**
arm64-v8a, Android 9 (API 28) or newer. The build is arm64-only on purpose —
other ABIs produce jars that can never load a model.

**Why will the APK not install over the old one?**
No release keystore is configured, so each build carries a different debug key
and Android refuses the update. Uninstall first. Adding the four secrets in
[RELEASE_SIGNING.md](RELEASE_SIGNING.md) fixes it permanently.

**How do I build it?**
Push a `v*` tag and let GitHub Actions do it — see
[BUILD_OPTIONS.md](../BUILD_OPTIONS.md) for the alternatives. Locally you also
need `glslc`; without it the Vulkan backend does not link.

**Is the build actually trustworthy?**
CI runs the unit and widget tests as a hard gate, then checks 16 KB page
alignment, that the APK's version equals the tag, that `libllama.so`,
`libggml*.so`, `libonnxruntime.so` and the mtmd/CLIP vision symbols are actually
present, that the Vulkan entry point is exported, and that the APK verifies as
signed. It writes a `SHA256SUMS` file.

**Is any of that proof it works?**
No. A green CI run is not evidence of runtime behaviour. The infinite "Thinking…"
bug of v1.1.0 compiled cleanly and passed every test, and only appeared on real
hardware. [DEVICE_TEST_CHECKLIST.md](DEVICE_TEST_CHECKLIST.md) is the pass that
has to happen before anything here is called verified.

## Project

**Why is the repo called Opendotsapk?**
That is the repository's name on GitHub. The app is LocalMind.

**Where do the design decisions live?**
`docs/` — one document per decision, each with the evidence that settled it:
[ADR-native-binding.md](ADR-native-binding.md),
[GPU_ACCELERATION.md](GPU_ACCELERATION.md),
[MODEL_SUPPORT.md](MODEL_SUPPORT.md),
[PAGE_ALIGNMENT.md](PAGE_ALIGNMENT.md),
[RELEASE_SIGNING.md](RELEASE_SIGNING.md),
[SPIKE-litert-lm.md](SPIKE-litert-lm.md), and the working record in
[AUDIT_PROGRESS.md](AUDIT_PROGRESS.md).

**How do I report a bug?**
Include the device model, SoC, Android version, and what you expected. Then open
**Activity → Diagnostics** and copy it — the app keeps a 500-entry in-memory log
ring precisely so a release build can still be debugged.
