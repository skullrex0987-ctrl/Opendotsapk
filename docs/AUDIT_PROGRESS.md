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
| A2 | Conversation history: wrong window, wrong format | todo | `history.take(10)` still selects the OLDEST turns and `_buildPrompt` still sends a flat transcript. Untouched. |
| A3 | Debug-key release signing, version drift | done (needs a secret) | Version now 1.2.0 and gated against the tag in CI. Signing reads a keystore but **no keystore exists yet** — CI correctly emits `*-DEBUGSIGNED-NOT-UPDATABLE.apk` and proves it with `apksigner`. The human must run `keytool` and add the 4 secrets; see `docs/RELEASE_SIGNING.md`. |
| A4 | Encryption key silently replaceable (data loss) | done | Typed NotFound/ReadError split; key minted only on NotFound; `resetDatabaseKey()` never auto-called; `allowBackup=false` + backup rules. |
| A5 | No stop control; cloud streams can hang | todo | Untouched. |
| A6 | Biometric fails open; recents screenshot leak | todo | Untouched. |

### Phase B — reliability, privacy, compliance

| ID | Task | Status | Note |
|---|---|---|---|
| B1 | 16 KB page alignment (`libonnxruntime.so` 0x1000) | todo | The C8 spike measured that the LiteRT engine AAR is already 16 KB aligned, but the app's own `libonnxruntime.so` is not. Untouched. |
| B2 | Cleartext traffic; API key in Gemini URL | todo | Untouched. |
| B3 | Model download integrity/robustness | done | Resume + pinning + SHA-256 + inactivity timeout. All 7 manifest hashes independently verified against HF LFS metadata. **Two sub-items open:** no real free-space probe (needs a plugin/MethodChannel) and downloads still die if Android suspends the app (needs a foreground service). |
| B4 | Documents & retrieval (PDF, chunking, encrypted search, logs, migrations) | todo | Untouched. Note `searchDocuments()` still LIKE-matches AES-GCM ciphertext, so it cannot work. |
| B5 | Privacy boundaries (default local, erase-all) | todo | Untouched. `wipe()` still has zero callers. |

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

---

## Evidence log

CI runs are cited by run id. Green = all steps succeeded.

| Date (IST) | Scope | Commit | CI run | Result |
|---|---|---|---|---|
| 2026-10-11 | A1 findings verified against source | (no commit) | — | n/a — read-only |
| 2026-10-11 | A1+A3+A4+B3+docs, first attempt | `56ea925` | `38135144800` | ❌ 1 compile error: `database_helper.dart:504` called `.value` on the sealed base `DecryptResult` (flow promotion failed after a `continue`). 161 tests had passed. |
| 2026-10-11 | A4 positive type check | `aa4b69f` | `38135507009` | ❌ tests passed, APK build failed: `ToolResult` imported from both `models.dart` and `tool_result.dart`. |
| 2026-10-11 | A1 removed the dead legacy `ToolResult` | `7c32bc3` | `38135906029` | ✅ **green, 11m24s, 180 tests.** Vulkan + vision + onnxruntime all verified present. |

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

