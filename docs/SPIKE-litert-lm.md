# SPIKE — adding a Google LiteRT-LM backend

Status: **spike / decision input**. Owner task: **C8 (LiteRT-LM backend)** in
`docs/AUDIT_PROGRESS.md`.

Scope: decide whether LocalMind should add Google LiteRT-LM as a second inference
backend, primarily to reach **MediaTek NPUs** through the LiteRT NeuroPilot
accelerator, and secondarily as a GPU path. This document is a go/no-go, not an
implementation plan.

**Method.** Every factual claim below was checked on the web on 2026-10-11 against
the current docs; the URL used is cited inline. Where the vendor docs are
ambiguous, or where I could only find a secondary source, it is marked
**unverified**. Vendor performance marketing is quoted only to be qualified, not
to be relied on. One first-hand measurement was taken: the `litertlm-android`
AAR was downloaded and inspected (size, ABI coverage, ELF page alignment, licence)
— those figures are reproducible from the Maven URL given.

---

## 1. How to integrate from Flutter

There is no first-party Flutter SDK. Google's own Flutter page says only:

> "LiteRT-LM is supported on Flutter using the community-maintained package
> `flutter_gemma`."
> — <https://developers.google.com/edge/litert-lm/flutter>

The supported languages are CLI/Python/Kotlin/C++ (Stable) and Swift/JavaScript
(Early Preview); Flutter is flagged **Community** in the same table
(<https://ai.google.dev/edge/litert-lm/overview>). So there are three realistic
integration routes:

| Route | What it is | MediaTek NPU? | Verdict |
|---|---|---|---|
| **A. Kotlin wrapper + MethodChannel/EventChannel** | Our own Kotlin plugin calls the *official* LiteRT-LM Kotlin API (`com.google.ai.edge.litertlm:litertlm-android`), streams tokens over an EventChannel | Yes — `Backend.NPU(nativeLibraryDir=…)` is vendor-agnostic | **Recommended** |
| **B. C++ / JNI + dart:ffi** | Build LiteRT-LM from source with Bazel and bind the C++ API | Yes, but we own the whole bridge | Not recommended |
| **C. Community Flutter package (`flutter_gemma` / now `flutter_edge_ai_litertlm`)** | dart:ffi over the LiteRT-LM **C API**, native lib fetched by a build hook | **No** — Qualcomm + Intel only | Good only if we drop the MediaTek goal |

**Recommendation: route A.** Reasons:

- The Kotlin API is Google's **Stable, supported** Android surface and ships as a
  Maven artifact (`com.google.ai.edge.litertlm:litertlm-android`, latest.release
  = 0.18.0 as of 2026-10-06 per
  <https://dl.google.com/android/maven2/com/google/ai/edge/litertlm/litertlm-android/maven-metadata.xml>).
  We do not reimplement the JNI bridge.
- The official JNI wrapper already does the fiddly NPU wiring. A documented
  LiteRT footgun is that on a dynamic-link build the NPU accelerator is silently
  disabled unless the *dispatch library directory* is passed explicitly; the
  Google responder states the Java/Android path does **not** suffer this "because
  the JNI wrapper sets the dispatch dir automatically from `nativeLibraryDir`"
  (<https://github.com/google-ai-edge/LiteRT/issues/7602>). Route B/C must handle
  this themselves.
- It matches the existing app pattern: `pubspec.yaml` already describes
  llama.cpp as "via MethodChannel", so a Kotlin plugin with an EventChannel for
  the token stream is consistent with the current architecture and testable
  without C++ toolchain work.
- Route B means adopting **Bazel 7.6.1 + NDK r28b** and building LiteRT-LM from
  source (<https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/getting-started/build-and-run.md>),
  which the project cannot even build locally today (no Flutter SDK, ~350 MB RAM,
  ~2.9 GB disk per `docs/AUDIT_PROGRESS.md`), and which roughly doubles CI cost
  for no extra capability.
- Route C is the cheapest route *if* the target is Snapdragon/Intel, but it does
  **not** expose the MediaTek NPU: the community engine's platform table lists
  NPU as "Qualcomm on Android … and Windows (Intel LunarLake / PantherLake)" and
  its Android NPU enablement is `qualcomm_npu` only
  (<https://fluttergemma.dev/docs/litertlm>). That rules Route C out for the
  stated MediaTek goal.

The Kotlin API surface we would bind (verified in the AAR's `classes.jar`):
`Engine`, `EngineConfig(modelPath, backend, visionBackend, audioBackend, cacheDir)`,
`Conversation`, `sendMessage` / `sendMessageAsync(Flow<Message>)`,
`SamplerConfig`, and `Backend` subtypes `CPU`, `GPU`, `NPU(nativeLibraryDir)`,
`GOOGLE_TENSOR`. The `NpuBrand` enum is `UNKNOWN / QUALCOMM / GOOGLE_TENSOR /
MEDIATEK / INTEL / SAMSUNG`, i.e. the API itself knows about MediaTek.

---

## 2. APK size impact per ABI

Measured from the current artifact, `litertlm-android-0.18.0.aar`
(<https://dl.google.com/android/maven2/com/google/ai/edge/litertlm/litertlm-android/0.18.0/litertlm-android-0.18.0.aar>,
downloaded and unzipped):

| Item | Uncompressed | Deflated (in-archive) |
|---|---|---|
| Whole AAR | 20,905,807 B (~19.9 MB) | — |
| `classes.jar` (Kotlin/Java API) | 191,250 B | 177,166 B |
| `jni/arm64-v8a/liblitertlm_jni.so` | **22,155,680 B (~21.1 MB)** | 9,706,385 B (~9.3 MB) |
| `jni/x86_64/liblitertlm_jni.so` | **26,353,160 B (~25.1 MB)** | 10,703,419 B (~10.2 MB) |

Note the AAR ships **only `arm64-v8a` and `x86_64`** — no `armeabi-v7a`. That is
fine for this app (arm64-v8a, and NPU is arm64-v8a-only anyway per
<https://developers.google.com/edge/litert/next/npu>).

For LocalMind (arm64-v8a only), the engine adds roughly:

- **~21 MB installed** (the uncompressed `.so`; modern AGP with the default
  `extractNativeLibs=false` maps native libs directly, so this lands in the APK
  as-is), or **~9–10 MB of download** if the `.so` is packaged compressed.
- **+~25 MB more** if we also ship `x86_64` for emulator parity.

This is the *engine only*. Vendor NPU runtimes are separate and much larger (see
§8): the community package measures the Qualcomm NPU stack at "about 22 MB more
to download and 83 MB more installed, plus a copy of the same size made on the
first NPU run"
(<https://fluttergemma.dev/docs/litertlm>). One community report lists
`libQnnHtpPrepare.so` alone at ~82 MB
(<https://github.com/finnff/LLMChatApp>). Google's sanctioned delivery is Play
Feature Delivery so those libraries are **not** in the base APK
(<https://developers.google.com/edge/litert/next/npu>).

---

## 3. Licence

- **LiteRT-LM** is **Apache-2.0**. Confirmed from the repository licence metadata
  (<https://github.com/google-ai-edge/LiteRT-LM>, "License: Apache License 2.0")
  and from the `LICENSE` file inside the AAR I downloaded, which begins
  "Apache License, Version 2.0". The AAR also ships a 2.2 MB
  `THIRD_PARTY_NOTICE.txt`, so the attribution obligation is real and must be
  carried into the app's notices.
- **Vendor runtimes are not open.** Qualcomm's QNN stack carries Qualcomm's own
  licence; the community package states "Qualcomm licenses its QNN runtime for
  redistribution inside an application only", and enabling it means accepting
  Qualcomm's AI Stack License
  (<https://fluttergemma.dev/docs/litertlm>). MediaTek's NeuroPilot SDK is
  governed by MediaTek's proprietary AIoT Software License Agreement, which
  grants a non-transferable licence to distribute the software "only in object
  code form and only as incorporated with Licensed Product or Application"
  (<https://mediatek.gitlab.io/genio/doc/android/license.html>), and full
  NeuroPilot is NDA-gated
  (<https://neuropilot.mediatek.com/resources/public/latest/en/docs/readme>).

**Compatibility:** Apache-2.0 (LiteRT-LM) is compatible with this app; it is a
permissive licence and only requires NOTICE/attribution. The binding constraint
is the **vendor runtimes**: we may redistribute the Qualcomm/MediaTek objects
only under their terms, and the MediaTek terms tie redistribution to the licensed
product/chipset. This is exactly why Google routes NPU runtimes through **Play
Feature Delivery** rather than the base APK
(<https://developers.google.com/edge/litert/next/npu>) — it keeps us inside the
vendor terms and off the hook for shipping another vendor's binaries to a device
that cannot use them. Whether LocalMind's own licence and the app-store listing
are compatible with bundling MediaTek NeuroPilot objects directly is **unverified**
and must be checked before any MediaTek NPU build ships.

---

## 4. Model format

LiteRT-LM runs **`.litertlm`** files only. Verified:

- The Kotlin guide's `modelPath` is a `.litertlm` path, and the NPU guide states
  "The LiteRT-LM runtime is designed to work with models in the `.litertlm`
  format" (<https://ai.google.dev/edge/litert/next/litert_lm_npu>).
- `.litertlm` is "a single unified container that packages your TFLite models,
  tokenizer files, external weights, and associated model metadata"
  (<https://developers.google.com/edge/litert-lm/file_builder>).

**GGUF does not work.** This is stated plainly by the community engine docs:
"Formats are not interchangeable: a GGUF file cannot run through LiteRT-LM, and
a `.litertlm` bundle cannot run through llama.cpp"
(<https://fluttergemma.dev/docs/litertlm>). The conversion path is
**PyTorch → `.litertlm`** via LiteRT Torch (`export_hf`, `bundle_litert_lm`), not
from GGUF (<https://developers.google.com/edge/litert/conversion/pytorch/genai>).
Consequence: the models this app already downloads and serves (GGUF, including
the vision/mtmd path) are **not reusable**; a LiteRT-LM backend needs a parallel
model-download and storage story.

**Available model families** (from the overview "Supported Models" table,
<https://ai.google.dev/edge/litert-lm/overview>, and the CLI guide):
Gemma 4 (E2B/E4B), Gemma-3n (E2B/E4B), Gemma3-1B, FunctionGemma, Phi-4-mini,
Qwen2.5 (0.5B/1.5B), Qwen3-0.6B, plus EmbeddingGemma 2 (text/vision/audio). The
pre-converted bundles live on the "litert-community" Hugging Face org.

---

## 5. Model sizes

From the LiteRT-LM overview table
(<https://ai.google.dev/edge/litert-lm/overview>), unless noted:

| Model | Size |
|---|---|
| FunctionGemma (base) | 289 MB |
| Gemma3-1B | 1,005 MB |
| Qwen3-0.6B | 586 MB |
| Qwen2.5-0.5B | 521 MB |
| Qwen2.5-1.5B | 1,598 MB |
| Gemma-3n-E2B | 2,965 MB |
| Gemma-3n-E4B | 4,235 MB |
| Gemma4-E2B | 2,583 MB |
| Gemma4-E4B | 3,654 MB |
| phi-4-mini | 3,906 MB |
| EmbeddingGemma 2 (740M / 440M / 270M) | 485 / 388 / 165 MB |

**NPU-specific bundles** are per-SoC and smaller for the tested configs. The
MediaTek NPU LLM table lists only two entries, both Gemma3-1B q4 per-channel with
1,280 context: **MT6989 → 985 MB**, **MT6991 → 986 MB**
(<https://ai.google.dev/edge/litert/next/litert_lm_npu>, mirrored at
<https://developers.google.cn/edge/litert/next/litert_lm_npu>). Qualcomm bundles
for the same model are ~658 MB across SM8750/SM8650/SM8550. Google Tensor lists
Gemma4-E2B at 2,642 MB and Gemma3-1B at 1,704 MB.

The headline chat models are **1–4 GB** — larger than the GGUF models this app
ships today. A multi-GB download is a product decision, not just an engineering
one.

---

## 6. minSdk compatibility with minSdk 28

- The **base engine AAR declares `minSdkVersion="24"`** — I read this from the
  `AndroidManifest.xml` inside `litertlm-android-0.18.0.aar`. So the engine itself
  is compatible with this app's **minSdk 28**.
- **GPU** needs the app to declare two `uses-native-library` entries
  (`libvndksupport.so`, `libOpenCL.so`), both `required="false"`
  (<https://developers.google.com/edge/litert-lm/android>) — available at API 28.
- **NPU is the catch.** Google's unified NPU guide requires **`minSdk = 31`** for
  the Play AI-Pack path ("API level 31+ is required for NPU support",
  <https://developers.google.com/edge/litert/next/npu>), while the per-vendor
  *source-build* pages say only that the NDK supports "API Level 28 (Android 9
  Pie)". So: the library loads at API 28, but the supported NPU *packaging* flow
  assumes API 31+. Reaching MediaTek NPU at minSdk 28 via bundled dispatch
  libraries is plausible but **unverified** — it is the un-sanctioned path.

If LocalMind keeps minSdk 28, the safe reading is: **CPU/GPU work at 28; NPU is a
31+ feature**, so NPU becomes a per-device capability that must degrade to GPU/CPU
below 31.

---

## 7. MediaTek SoCs covered by LiteRT NeuroPilot

**The audit's list is correct — verified verbatim.** The current MediaTek NPU page
lists exactly:

> Dimensity 7300 (MT6878), Dimensity 8300 (MT6897), Dimensity 9000 (MT6983),
> Dimensity 9200 (MT6985), Dimensity 9300 (MT6989), Dimensity 9400 (MT6991),
> Dimensity 9500 (MT6990).
> — <https://developers.google.com/edge/litert/next/mediatek>

**One important correction to the *implication*, not the list.** Those seven SoCs
are covered by the **LiteRT `CompiledModel` API** (the generic ML path). For
**LLMs via LiteRT-LM**, the only MediaTek SoCs with published NPU bundles are
**MT6989 (D9300) and MT6991 (D9400)** — the LLM NPU model table has no rows for
7300/8300/9000/9200/9500
(<https://ai.google.dev/edge/litert/next/litert_lm_npu>). So "seven MediaTek SoCs"
overstates LLM-NPU reach: for *this app's* use case it is **two**.

For completeness, Qualcomm's LiteRT NPU list is SM8850 / SM8750 / SM8650 / SM8550
/ SM8475 / SM8450 (<https://developers.google.com/edge/litert/next/qualcomm>), and
Google Tensor G5/G6 and Samsung Exynos AI LiteCore are also supported vendors
(<https://developers.google.com/edge/litert/next/npu>).

---

## 8. Vendor runtime libraries required, and how they ship

**Routing.** On Android, LiteRT does not auto-detect the accelerator: the app must
ship "only the dispatch library matching your target device's chipset"
(<https://github.com/google-ai-edge/LiteRT/issues/4571>). There, Googlers state
"Currently, we support Qualcomm, MediaTek, and Google Tensor chipsets."

**Google's sanctioned shipping method — Play Feature Delivery.** Download either
`litert_npu_runtime_libraries.zip` (AOT) or `..._jit.zip` (on-device), which
unpacks into per-vendor modules:

```
litert_npu_runtime_libraries/
  google_tensor_runtime/  samsung_runtime/  mediatek_runtime/
  qualcomm_runtime_v69/  qualcomm_runtime_v73/  ..._v75/ ..._v79/ ..._v81/
```

These are wired as `dynamicFeatures` (on-demand / install-time) and filtered by
device with `NpuCompatibilityChecker` + device-targeting config; the base config
also requires `minSdk = 31`, `abiFilters = arm64-v8a`, and
`jniLibs.useLegacyPackaging = true`
(<https://developers.google.com/edge/litert/next/npu>).

**Qualcomm (QAIRT / QNN).** Requires the QAIRT SDK's QNN libraries on device —
`libQnnHtp.so`, `libQnnHtpPrepare.so`, `libQnnSystem.so`, and the matching
`libQnnHtpV##Stub.so` / `libQnnHtpV##Skel.so` for the Hexagon arch, plus a
vendor dispatch `.so` (`libLiteRtDispatch_Qualcomm.so`). For the source-build path
the docs walk through pushing these via `adb push $QAIRT_ROOT/lib/aarch64-android/…`
(<https://ai.google.dev/edge/litert/next/litert_lm_npu>). Library roles are
documented at <https://docs.qualcomm.com/doc/80-63442-10/topic/backend.html>. For
an app, the community package shows the intended shape: fetch
`com.qualcomm.qti:qnn-runtime` from Maven, verify SHA-256, re-align, and bundle —
~22 MB download / ~83 MB installed. **AOT context binaries are not portable across
major QNN versions**; a QNN v2.44-compiled bundle will not load on a v2.37 runtime
(a real, reproduced failure on community hardware,
<https://github.com/finnff/LLMChatApp>).

**MediaTek (NeuroPilot).** Requires the NeuroPilot runtime + the LiteRT MediaTek
dispatch library; LiteRT-LM's source build produces it with
`bazel build --config=android_arm64 @litert//litert/vendors/mediatek/dispatch:dispatch_api_so`,
and for an app the `mediatek_runtime` Play Feature module is the delivery vehicle
(<https://ai.google.dev/edge/litert/next/litert_lm_npu>,
<https://developers.google.com/edge/litert/next/npu>). Redistribution terms are
MediaTek's (see §3).

**Bottom line:** the base APK does **not** carry NPU support; it is realised
through Play Feature Delivery or bundled `jniLibs`, per vendor, and only one
vendor's dispatch library may be present for the device class you target.

---

## 9. Production-ready, or early access?

Mixed, and the honest answer is **"production-ready framework, thin NPU
coverage."**

- **Framework level: production.** LiteRT-LM is described as "production-ready"
  and "powers on-device GenAI experiences in Chrome, Chromebook Plus, Pixel Watch"
  (<https://github.com/google-ai-edge/LiteRT-LM>). Kotlin/C++/Python are
  **Stable**; Swift/JS are Early Preview; **Flutter is Community**
  (<https://ai.google.dev/edge/litert-lm/overview>).
- **NPU level: maturing, and the messaging has moved.** The source-build guide
  still says NPU is behind an **Early Access Program**
  (<https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/getting-started/build-and-run.md>),
  while the December-2025 MediaTek announcement says "LiteRT NPU support is now
  available to all developers" and promises "optimized, production-ready support"
  for the Dimensity 9500
  (<https://developers.googleblog.com/en/mediatek-npu-and-litert-powering-the-next-generation-of-on-device-ai/>,
  <https://www.mediatek.com/tek-talk-blogs/mediatek-npus-neuropilot-and-litert-are-ready-to-power-ai-in-millions-of-devices>).
  The docs are inconsistent with each other here; treat NPU as GA-on-newest-SoCs,
  early elsewhere.
- **The Kotlin NPU path specifically has been rough.** A developer running
  Gemma3 on the NPU through the new Kotlin API hit "Failed to initialize Dispatch
  API" and worked around the native-library loading by hand; the reply notes "NPU
  support for the Kotlin API is an …" in-progress
  (<https://github.com/google-ai-edge/LiteRT/issues/4571>). On the community
  Flutter path, "NPU is a Gemma 4 story today" and **Gemma 3 on NPU fails
  silently** — the model answers from the first prefill chunk alone, fluently,
  with no error and nothing in the log
  (<https://fluttergemma.dev/docs/litertlm>). A silent-wrong-answer failure mode
  is worse than a crash.
- **Per chip:** newest flagships (Dimensity 9500, Snapdragon 8 Elite Gen 5,
  Tensor G6) are the "production-ready" claims; older listed SoCs are
  supported-but-thin, with only Gemma3-1B-class bundles published for MediaTek.

---

## 10. 16 KB page-size alignment (Android 15 / Play requirement)

Requirement: apps targeting API 35+ must support 16 KB page sizes on 64-bit
devices, with an update-blocking deadline from **2027-02-01**; native libraries'
ELF segments must be 16 KB-aligned (NDK r28+ compiles this by default)
(<https://developer.android.com/guide/practices/page-sizes>).

**Verified by inspection:** the LiteRT-LM Android engine **is** 16 KB-aligned.
I unpacked `jni/arm64-v8a/liblitertlm_jni.so` from the 0.18.0 AAR and read its
program headers — every `LOAD` segment has `Align 0x4000` (= 16384):

```
LOAD … 0x14510e0 … R E 0x4000
LOAD … 0x0c1760  … RW  0x4000
LOAD … 0x00ad48  … RW  0x4000
```

**Vendor libraries are the risk, not LiteRT-LM.** The community package has to
explicitly "raise the Hexagon libraries to the 16 KB page alignment Google Play
requires" when it fetches the Qualcomm runtime — i.e. **the Qualcomm Hexagon
`.so`s are not 16 KB-aligned as shipped and must be re-aligned**
(<https://fluttergemma.dev/docs/litertlm>). The alignment of the **MediaTek
NeuroPilot** runtime libraries as delivered is **unverified**. Any NPU shipping
path must run the same check (`readelf -l … | grep LOAD`, look for `0x4000`) on
every vendored `.so` before it goes into a release, or the app will fail Play's
16 KB check.

---

## 11. Recommendation

**Verdict: NO-GO as a general-purpose acceleration backend. GO — narrowly — for
an NPU-only feature on a small, whitelisted device set, and only via a bespoke
Kotlin wrapper.**

Reasoning:

1. **It does not replace llama.cpp.** GGUF does not run on LiteRT-LM and its
   models are not reusable (§4). Adding it means a second model format, a second
   download/store path, and a second tokenizer/chat-template stack — permanent
   dual maintenance.
2. **The CPU/GPU gains do not justify it.** The framework's own numbers show
   Android GPU prefill leaps but **decode barely moves** (Gemma4-E2B on S26 Ultra:
   CPU 47 → GPU 52 tok/s decode; prefill 557 → 3808), and decode is what makes an
   assistant feel fast (<https://ai.google.dev/edge/litert-lm/overview>). The
   community engine independently reports GPU decode *slower than CPU* on some
   devices and a **Mali crash** in the OpenCL accelerator
   (<https://fluttergemma.dev/docs/litertlm>). This app's existing Vulkan path
   already covers Adreno+Mali without a second backend.
3. **The MediaTek NPU goal is real but tiny today.** LiteRT NeuroPilot is the
   only realistic route to a MediaTek NPU (the app's own `GPU_ACCELERATION.md`
   correctly says so). But only **MT6989 and MT6991** have published LLM NPU
   bundles, with a single Gemma3-1B-class model (§5, §7). That is not "reach
   MediaTek NPUs across the fleet"; it is two flagship chips and one model.
4. **The cheap Flutter route cannot reach MediaTek.** The community package
   (Google's recommended Flutter path) enables Qualcomm and Intel NPU only, so it
   cannot serve the stated goal (§1). Reaching MediaTek means owning a Kotlin
   `MethodChannel` plugin against the official API — real work, and the Kotlin
   NPU path itself has open rough edges (§9).
5. **Packaging, licence and 16 KB costs are non-trivial.** NPU support requires
   Play Feature Delivery (minSdk 31, arm64-only), per-vendor dispatch libraries,
   vendor licences that restrict redistribution (§3), and a 16 KB-alignment audit
   of every vendored `.so` (§10).

**What a GO would actually look like (if pursued):**

- A Kotlin plugin binding `com.google.ai.edge.litertlm:litertlm-android` over
  MethodChannel/EventChannel, feature-flagged and **off by default**.
- NPU enabled only on a whitelist (`NpuBrand.MEDIATEK` and SoC in {MT6989,
  MT6991} at first), with hard fallback to the existing llama.cpp backend.
- Models delivered per-SoC via Play Feature Delivery; nothing multi-GB in the
  base APK.
- A 16 KB alignment gate on all vendored `.so`s in CI, and a log line that
  records `model.activeBackend` (the community package notes the engine can fall
  back to CPU *silently* — <https://fluttergemma.dev/docs/litertlm>).
- Treat the audit's "7 MediaTek SoCs" as **7 for generic LiteRT, 2 for LLM NPU**
  and set expectations accordingly.

**On vendor "12x faster" numbers — do not generalise them.** Google's blog says
NPU-hardware-accelerated Gemma is "up to 12x faster compared to CPU, and 10x
compared to GPU", with "over 1600 tokens/sec for prefill and 28 tokens/sec for
decode (with 4K context)" for Gemma 3n E2B
(<https://developers.googleblog.com/en/mediatek-npu-and-litert-powering-the-next-generation-of-on-device-ai/>).
Read the qualifiers: that is a **12× *prefill* / integer-quantized Gemma** figure on
a **Dimensity 9500 / Vivo X300 Pro**, against a CPU and GPU baseline the vendor
chose, on a model specifically recompiled for that NPU. Decode — the number a chat
user perceives — is **28 tok/s**, which is not 12× anything, and the community
numbers show single-digit decode differences on mainstream hardware. Vendor ratios
describe one chip, one model and one benchmark harness; they are not a transferable
expectation for LocalMind's fleet.
