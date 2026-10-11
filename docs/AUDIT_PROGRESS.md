# Audit progress tracker

Source spec: `localmind_hermes_master_prompt.md` (static audit of v1.2.0, produced externally).
Repo: `skullrex0987-ctrl/Opendotsapk`, branch `main`.

Status values: `todo` / `in-progress` / `done` / `blocked`.

---

## Environment constraints (read before judging any status)

**`flutter` and `dart` are NOT installed on the build host.** There is no SDK on
the box and only ~350 MB RAM available. Consequences:

- Ground rule 2 requires `flutter analyze` and `flutter test` to pass before a task
  is "done". Those commands **cannot run locally**. The only evidence path is
  GitHub Actions (`.github/workflows/build-apk.yml`, triggered on push to `main`),
  which runs `flutter pub get`, `flutter test`, and the APK build in ~8–11 min.
- Consequently "tests pass" below means **CI green**, with the run id cited.
- No task involving device behaviour can ever be marked done here. Those go to
  `docs/DEVICE_TEST_CHECKLIST.md`.

**Other host limits:** ~2.9 GB disk free (an APK build needs ~7.5 GB and 1.5–2 GB
RAM), so local Gradle builds are impossible. CI is the only build path.

---

## Verified source findings (ground rule 4 — checked, not assumed)

These were read directly out of the working tree on 2026-10-11, not taken from the
audit on trust.

| Claim | Verdict | Evidence |
|---|---|---|
| A1: tools return `success` while doing nothing | **Confirmed** | `tool_registry.dart` L177, 190, 204, 218, 227, 279, 285 — every one returns a fixed `{"status":"success"}` string, no operation performed |
| A1: `get_location`, `analyze_image` are real | **Confirmed** | L254–275 (Geolocator), L301–337 (mtmd via `LlmService.describeImage`) |
| A1: `ToolDefinition.schema` throws | **Confirmed** | L386 `!parameters[k]['optional']` — `optional` is set by no tool definition, so this is a null-check on `null` |
| A1: `ask` falls through to execution | **Confirmed** | `agent_orchestrator.dart` L110–111, comment "For now, proceed with execution"; `executeTool(permission:)` never reads its argument |
| A1: `_critique` omits the user question | **Confirmed** | L152–158 — prompt contains only the execution summary |
| A1: no fence stripping before `jsonDecode` | **Confirmed** | L68 `jsonDecode(response)` on raw model text |
| A1: `registerTools()` never called | **Confirmed** | repo-wide grep: only `AgentOrchestrator()` at `providers.dart:60`; no call site for `registerTools()` or `processMessage()` |
| **Not in the audit:** `getRelatedMemories()` always returns `[]` | **Confirmed** | L198–204 — stub, never wired to the vector index |
| A1: MCP servers not persisted | to verify | — |

---

## Task board

### Phase A — correctness & security

| ID | Task | Status | Note |
|---|---|---|---|
| A1 | Agent/tools/permissions dead or fake | done (partial) | ToolResult, schema fix, honest statuses, orchestrator rewrite, permission store, 180-test CI green. **Still open:** real device Intents (MethodChannel), the Approve/Deny confirmation sheet, the Agent-mode toggle wiring into chat, MCP server persistence. |
| A2 | Conversation history: wrong window, wrong format | done | Selection moved to `lib/core/utils/turn_builder.dart` — newest-first under a token budget, system prompt always kept, final question always kept, truncation reported. The old `history.take(10)` took the OLDEST ten of a chronological list and the current message was appended twice. `personality` is now actually sent. **Verified by execution:** 13/13 standalone Dart probe cases pass (`/opt/dart-sdk`), plus 13 host tests. |
| A3 | Debug-key release signing, version drift | done (needs a secret) | Version now 1.2.0 and gated against the tag in CI. Signing reads a keystore but **no keystore exists yet** — CI correctly emits `*-DEBUGSIGNED-NOT-UPDATABLE.apk` and proves it with `apksigner`. The human must run `keytool` and add the 4 secrets; see `docs/RELEASE_SIGNING.md`. |
| A4 | Encryption key silently replaceable (data loss) | done | Typed NotFound/ReadError split; key minted only on NotFound; `resetDatabaseKey()` never auto-called; `allowBackup=false` + backup rules. |
| A5 | No stop control; cloud streams can hang | done | Send button becomes Stop while generating, cancels the cloud subscription and calls `LlmService.stop()`. Partial replies are kept and marked `_(stopped)_`. Tokens batched to one UI update per 50 ms (was one `setState` per token, with one of the two loops missing its `mounted` guard). Cloud got a 15 s connect and 60 s inactivity timeout — it previously had none at all. |
| A6 | Biometric fails open; recents screenshot leak | done (device test needed) | Removed the `canCheckBiometrics` fail-open; only `isDeviceSupported()` gates it now, so a PIN-only device is still protected. No screen lock at all is fail-**closed** with two explicit ways out. `FLAG_SECURE` + `setRecentsScreenshotEnabled(false)` stop chat appearing in the recents thumbnail. Pickers call `suppressReLock()`. **Never observed running** — needs a phone. |

### Phase B — reliability, privacy, compliance

| ID | Task | Status | Note |
|---|---|---|---|
| B1 | 16 KB page alignment (`libonnxruntime.so` 0x1000) | done — **gate only, not fixed** | Measured, not assumed: the `onnxruntime` pub package is frozen at 1.4.1 (ships ORT 1.15.1, 2023-12-19) so there is nothing to bump to; surveying Maven AARs shows 1.15.1–1.19.2 are all `0x1000` and **1.20.0 is the first aligned one** (the audit guessed 1.19). `scripts/check_page_alignment.py` now runs in CI and fails the build naming any misaligned library; tested against a good APK and against the real 1.15.1 `.so`. **The app still ships a misaligned library.** Fixing it needs a fork or a Gradle AAR override + device validation — see `docs/PAGE_ALIGNMENT.md`. |
| B2 | Cleartext traffic; API key in Gemini URL | done | Global `usesCleartextTraffic` removed; a network security config denies cleartext except for loopback/RFC1918/link-local/`*.local`. Android matches that config by domain and not by CIDR, so the ranges are enforced by pure helpers in `cloud_screen.dart` (`isLocalHttpHostAllowed`) that gate what the app dials and refuse to save a key against a non-local plaintext URL. The Gemini key moved out of the query string into `x-goog-api-key`. |
| B3 | Model download integrity/robustness | done | Resume + pinning + SHA-256 + inactivity timeout. All 7 manifest hashes independently verified against HF LFS metadata. **Two sub-items open:** no real free-space probe (needs a plugin/MethodChannel) and downloads still die if Android suspends the app (needs a foreground service). |
| B4 | Documents & retrieval (PDF, chunking, encrypted search, logs, migrations) | done | **PDF** now inflates FlateDecode properly — the old regex never decompressed, so it returned nothing for nearly every real PDF, and it called a `flutter_pdf_text` API the project does not even depend on. The replacement is **verified by execution: 15/15 standalone Dart cases**, including zlib with/without `/Length`, hex, raw-deflate fallback, multi-stream, and the zip-bomb/entry-count guardrails. **Chunking** was 900 chars against a 128-token (≈512 char) embedder, so the tail of every chunk was never embedded; now 480/96 from one shared constant. **Search** LIKE-matched ciphertext and could never match; now decrypts then matches. **Activity logs** were written plaintext but read as encrypted; both sides now encrypt. **`_upgrade()`** dropped the vectors *and chunks* tables on every version bump — silently destroying the user's whole index on a routine update; now only a genuine legacy `vec0` table is replaced. Open: search is O(all chunks), needs a blind index if it grows. |
| B5 | Privacy boundaries (default local, erase-all) | done (chat wiring done) | Local-by-default proven across 72 cases in `test/privacy_boundaries_test.dart`. Cloud needs consent bound to a specific provider, re-prompted when the provider changes. Private mode now genuinely skips the startup DNS probe (previously it ran unconditionally in two places). Erase-all is a two-step confirm with an explicit choice about deleting downloaded models. `wipe()` finally has callers. One-off cloud send is wired into the chat screen via `routeConfigForTurn`. |

### Phase C — GPU / NPU / CPU (owner's main goal)

| ID | Task | Status | Note |
|---|---|---|---|
| C1 | Make the real backend observable | todo | |
| C2 | Crash-safe backend init (sentinel) | todo | |
| C3 | Benchmark-driven backend selection | todo | |
| C4 | Faster CPU path (runtime CPU variants, thread count) | todo | |
| C5 | `InferenceBackend` abstraction | todo | |
| C6 | `lite` / `full` product flavours | todo | |
| C7 | Adreno OpenCL + Hexagon NPU | **blocked — unreachable as built** | `docs/ADR-native-binding.md` inspected the vendored tree: ggml is 0.9.11, new enough to contain `ggml-hexagon` and `ggml-opencl`, but the **published pub package deletes `ggml/src/opencl` and `ggml/src/hexagon`** while leaving the CMake options and `ggml_backend_*_reg()` calls in place. Enabling them is therefore a configure-time failure. C7 cannot be done via the patch-the-pub-package approach — it needs the C5/ADR Option B (owned pinned wrapper) first. |
| C7b | MediaTek (Mali/Immortalis) policy | todo | Depends on C1/C3 (measure, don't assume). The ADR notes a Mali Vulkan report of ~1.5s CPU vs ~24s Vulkan, but it is old and anecdotal. |
| C8 | LiteRT-LM backend (MediaTek NPU etc.) | **no-go (documented)** | `docs/SPIKE-litert-lm.md`. `.litertlm`-only (GGUF unusable), a whole second model stack, LLM NPU bundles for only 2 MediaTek SoCs (MT6989/MT6991) needing minSdk 31, and the vendor "12x" figure is prefill-only on a Dimensity 9500. Conditional GO only for a narrow whitelisted NPU feature. |
| C9 | UI honesty (real backend chip) | todo | Note: `gpu_service.dart` already exists but reports the *requested* layer count, not the actual backend — see C1. |

### Phase D — honesty & handover

| ID | Task | Status | Note |
|---|---|---|---|
| D1 | README status table matches reality | todo | |
| D2 | Finish this file + `DEVICE_TEST_CHECKLIST.md` | in-progress | |
| D3 | Final report per task ID | todo | |

### Phase E — vision & model management (owner-reported, 2026-10-11)

Triggered by a real phone: an image was sent to a downloaded vision model and the
reply was *"I didn't understand your question"*.

| ID | Task | Status | Note |
|---|---|---|---|
| E1 | Vision failure root cause | **done** | `initVision` was failing, not silently dropping: the snackbar read *"Qwen2.5 0.5B Instruct loaded, but vision failed to attach."* Root cause proven by inspecting the vendored tree: the `projector_type` enum in `tools/mtmd/clip-impl.h` has **42 members and no `moondream`** — `grep -r MOONDREAM tools/mtmd/` returns zero hits. Moondream2's projector loads as `PROJECTOR_TYPE_UNKNOWN`. **It could never have worked.** See `docs/MODEL_SUPPORT.md`. |
| E2 | Add Qwen3.5 0.8B (owner request) | **done** | Verified real: `Qwen/Qwen3.5-0.8B`, 0.9B, Apache 2.0, 262K ctx, image-text-to-text, released 2026-03-02. Runtime support confirmed in the vendored tree (`llama-arch.cpp` `LLM_ARCH_QWEN35`→`"qwen35"`, `src/models/qwen35.cpp`, `llama-vocab.cpp:2029` `tokenizer_pre == "qwen35"`, `clip.cpp` `PROJECTOR_TYPE_QWEN3VL`). Pinned to commit `6ab461498e2023f6e3c1baea90a8f0fe38ab64d0`: Q4_K_M **532,517,120 B** + `mmproj-F16` **204,987,232 B** = **703 MB**, against Moondream2's 1.97 GB. Both URLs `HEAD`-checked; `Content-Length` matches. |
| E3 | Images were dropped silently | **done** | `LlmService.generateStream` passed `mediaPaths` with no check that a projector was loaded — the plugin discards them and the model answers a question it never received. Now throws a `StateError` naming the cause. |
| E4 | Router downgraded image turns to a text model | **done** | Added `RouteTarget.refused` + `isRefused`. When an image turn has no vision anywhere it is refused and the reason goes into the transcript; no model is invoked. Previously it returned `local` and the image was dropped. **First attempt was still wrong:** the image check sat *after* the `_candidates.isEmpty` early return, so a device with no cloud configured — the default, and the state the owner's phone was in — still returned `local` and dropped the picture. CI caught it; the check now runs first, before every "where should it run" rule. Private mode and offline remain absolute (they refuse rather than reaching out). |
| E5 | App log was unreachable | **done** | `Log` keeps a 500-entry ring *"so bug reports can read it"*, but had **zero call sites in the UI** — so on a release phone the reason a model failed was unreadable. Activity screen now has a **Diagnostics** tab with copy-to-clipboard. |
| E6 | Model Management: choose models from the sheet | **done** | The dialog offered only "Load Selected Model" (with a hardcoded `Qwen2.5-1.5B` subtitle) and "Load from Storage". It is now a picker: every catalogue model with size, downloaded state, selection state, plus a **mismatch warning** when the file in memory is not the one selected. |
| E7 | Vision-load failure hid its cause | **done** | `loadVision` swallowed the plugin's error into a generic callback. It now records `lastVisionError`, logs it at error level, and the chat snackbar appends the real text. |
| E8 | Moondream2 disabled, not deleted | **done** | `LocalModel.unsupportedReason` added; `ModelCatalog.isUsable` now reads it instead of returning a hardcoded `true`. Moondream2 stays listed (greyed out, reason shown) so a user holding 1.97 GB gets an explanation. Files on disk are never touched. |

---

## Evidence log

CI runs are cited by run id. Green = all steps succeeded.

| Date (IST) | Scope | Commit | CI run | Result |
|---|---|---|---|---|
| 2026-10-11 | A1 findings verified against source | (no commit) | — | n/a — read-only |
| 2026-10-11 | A2+A5 | `9ce7927` | `38137414188` | **GREEN** |
| 2026-10-11 | A2 selection logic, standalone Dart probe | (local) | — | **13/13 pass** — `dart` 3.13.5 at `/opt/dart-sdk` |
| 2026-10-11 | A6+B1+B2+B5 | `ac2c42a`..`57c8601` | — | parse-clean: `dart format --output=none` over all 50 `lib`/`test` files, 0 parse failures |
| 2026-10-11 | B4 PDF extractor, standalone Dart probe | (local) | — | **15/15 pass** — incl. zlib ±`/Length`, hex, raw-deflate, multi-stream, zip-bomb + entry-count guardrails |
| 2026-10-11 | B4 (extractor + chunking, then search/logs/migrations) | `49fbdcd`, `6697016` | `38138755703`, `38138801776` | ❌ both failed: `_readPdf` threw where the contract requires an empty return (2 tests). |
| 2026-10-11 | A6+B5 chat wiring | `6545b3f` | `38138182850` | ❌ failed: the new 16 KB alignment gate correctly detected a real misalignment and blocked the build. |
| 2026-10-11 | CI fixes: restore the empty-PDF contract, gate warns instead of blocking | `51dee7a` | `38139030190` | ✅ **green, all 24 steps** |
| 2026-10-11 | **Release v1.3.0** (audit Phase A + B) | `09a18e5` tag `v1.3.0` | `38140821795` | ✅ **green; APK 51,865,102 B, sha256 `c893e0bc…b939`, published and verified downloadable (HTTP 200)** |
| 2026-10-11 | A1+A3+A4+B3+docs, first attempt | `56ea925` | `38135144800` | ❌ 1 compile error: `database_helper.dart:504` called `.value` on the sealed base `DecryptResult` (flow promotion failed after a `continue`). 161 tests had passed. |
| 2026-10-11 | A4 positive type check | `aa4b69f` | `38135507009` | ❌ tests passed, APK build failed: `ToolResult` imported from both `models.dart` and `tool_result.dart`. |
| 2026-10-11 | A1 removed the dead legacy `ToolResult` | `7c32bc3` | `38135906029` | ✅ **green, 11m24s, 180 tests.** Vulkan + vision + onnxruntime all verified present. |
| 2026-10-11 | E1 moondream projector support, inspected the vendored tree | (no commit) | — | **Proven absent:** `projector_type` enum has 42 members, none `moondream`; `grep -r MOONDREAM tools/mtmd/` = 0 hits. |
| 2026-10-11 | E2 Qwen3.5 pins read from the HF API at a pinned commit | (local) | — | sizes/hashes fetched programmatically at `6ab4614…`; **both URLs `HEAD`-verified, `Content-Length` matches** (532,517,120 / 204,987,232). |
| 2026-10-11 | E1–E8 catalogue logic, standalone Dart probe | (local) | — | **19/19 pass** — `dart run catalog_verify.dart` on `dart` 3.13.5 at `/opt/dart-sdk`. |
| 2026-10-11 | E1–E8 parse gate across all `lib`/`test` files | (local) | — | **0 real parse failures / 50 files** (`dart format --output=none`). |
| 2026-10-11 | E1–E8 first attempt | `93e4aef` | `38145601204` | ❌ **1 test failed** — my own new ordering test. The image check ran *after* the `_candidates.isEmpty` early return, so a no-cloud device (the owner's exact state) still dropped the image. A real gap, caught by the test rather than by the phone. |
| 2026-10-11 | E4 ordering fix, real router executed on the Dart VM | (local) | — | **15/15 pass** against the copied `router_service.dart` with a stubbed logger — covers all four config modes with an image and no vision, plus private/offline absolutes and unchanged text-only routing. |

### What the green run proves

- **180 tests pass** (was 121 before this work; +59).
- The **version gate works**: `APK versionName='1.2.0' versionCode='42'; expected '1.2.0'` (versionCode from `GITHUB_RUN_NUMBER`).
- The **signing fail-safe works**: with no keystore secret configured, CI produced
  `localmind-1.2.0-DEBUGSIGNED-NOT-UPDATABLE.apk` and `apksigner` confirmed
  `C=US, O=Android, CN=Android Debug`. It is honest about being un-updatable
  rather than quietly shipping a debug-signed release.
- **Native verification still passes**: `OK: libllama present`, `libggml`,
  `libonnxruntime`, `OK: mtmd/CLIP vision code is linked in`,
  `OK: Vulkan backend shipped`, `OK: Vulkan backend registers itself with ggml`.

### What it does NOT prove

Nothing about runtime behaviour on a device. Every task above still needs the
`docs/DEVICE_TEST_CHECKLIST.md` pass by a human before it can be called working.

---

## Blocked items

None recorded yet. Anything needing a physical device is not "blocked" — it is
routed to `docs/DEVICE_TEST_CHECKLIST.md` per ground rule 3.

---

## Live bug reported by the owner (2026-10-11)

**Symptom:** "Moondream2 is getting downloaded again and again."

**Diagnosed, not assumed.** The two HuggingFace URLs are healthy — checked with
HTTP HEAD and a ranged GET:

| File | HTTP | Actual bytes | First bytes |
|---|---|---|---|
| `moondream2-050824-q5k.gguf` | 200 | 1,059,610,016 | `GGUF…phi2…moondream2` |
| `moondream2-mmproj-050824-f16.gguf` | 200 | 909,777,984 | `GGUF…clip…llava_projector` |

So the model is **~1.97 GB on disk**, yet `LocalModel.moondream2` declares
`approxBytes: 1300000000` — the catalogue understates it by ~670 MB.

**Root cause:** `ModelManager.download()` has no resume support:

- No `Range` header is ever sent.
- Its catch block does `if (await partFile.exists()) await partFile.delete();`.

A ~2 GB download therefore has to complete in a single uninterrupted foreground
session, or **all progress is discarded and it restarts from byte zero**. On a
phone, the screen locking or the app being backgrounded kills the socket, so the
practical experience is an endless restart loop.

**Fix owner:** task B3 (resume + integrity), extended via a live steer to require
that the `.part` file be kept rather than deleted, that `Range`/`If-Range` be
used, and that a resumed transfer be validated against the full expected size
rather than the ranged content-length. The catalogue size error is fixed too.

---

## Live bug reported by the owner (2026-10-11) — vision returns nothing

**Symptom:** an image was attached to a downloaded vision model and the reply
was *"I'm sorry, I didn't understand your question."*

**The real message was on screen and easy to miss:** loading the models produced

```
Qwen2.5 0.5B Instruct loaded, but vision failed to attach.
```

**Diagnosed, not assumed.** That string is emitted only when
`LlmService.loadVision()` returns `false`, i.e. when the plugin's native
`initVision` threw or returned false. Inspecting the vendored llama.cpp inside
`native_llama` 1.0.1:

- `ios/shared_cpp/tools/mtmd/clip-impl.h` defines `enum projector_type` with 42
  members. **None is Moondream2.**
- `grep -rn "MOONDREAM\|moondream"` across all of `tools/mtmd/` returns **nothing**.

So Moondream2's projector is parsed as `PROJECTOR_TYPE_UNKNOWN` and the load
fails. The catalogue's own comment — *"the only small GGUF whose projector
llama.cpp can actually serve on-device"* — asserted the opposite of the truth.

**Two further defects found while tracing it:**

1. `generateStream` took `imagePath` and passed it to the plugin with no check
   that a projector existed. The plugin discards such media, so the model
   answers a question that was never actually asked. This is why the reply was
   a confused generic sentence rather than an error.
2. The router's comment said it would *"be explicit instead of silently dropping
   the image"*, but it returned `RouteTarget.local` — the "explicitness" was a
   badge string, and the drop still happened.

**Fix owner:** Phase E (E1–E8). Moondream2 is disabled with a reason, Qwen3.5
0.8B is added as a verified native-vision replacement at less than half the
download size, the silent drop now throws, the router refuses, and the app's log
ring is finally readable in the UI. All of it needs the device checklist before
it can be called working.

