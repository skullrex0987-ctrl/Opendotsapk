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
| A1 | Agent/tools/permissions dead or fake | in-progress | Findings confirmed. Implementing: `ToolResult`, MethodChannel intents, `ToolPermissionStore`, planner/critic fix, agent-mode toggle. |
| A2 | Conversation history: wrong window, wrong format | todo | |
| A3 | Debug-key release signing, version drift | todo | |
| A4 | Encryption key silently replaceable (data loss) | todo | |
| A5 | No stop control; cloud streams can hang | todo | |
| A6 | Biometric fails open; recents screenshot leak | todo | |

### Phase B — reliability, privacy, compliance

| ID | Task | Status | Note |
|---|---|---|---|
| B1 | 16 KB page alignment (`libonnxruntime.so` 0x1000) | todo | |
| B2 | Cleartext traffic; API key in Gemini URL | todo | |
| B3 | Model download integrity/robustness | todo | |
| B4 | Documents & retrieval (PDF, chunking, encrypted search, logs, migrations) | todo | |
| B5 | Privacy boundaries (default local, erase-all) | todo | |

### Phase C — GPU / NPU / CPU (owner's main goal)

| ID | Task | Status | Note |
|---|---|---|---|
| C1 | Make the real backend observable | todo | |
| C2 | Crash-safe backend init (sentinel) | todo | |
| C3 | Benchmark-driven backend selection | todo | |
| C4 | Faster CPU path (runtime CPU variants, thread count) | todo | |
| C5 | `InferenceBackend` abstraction | todo | |
| C6 | `lite` / `full` product flavours | todo | |
| C7 | Adreno OpenCL + Hexagon NPU | todo | |
| C7b | MediaTek (Mali/Immortalis) policy | todo | |
| C8 | LiteRT-LM backend (MediaTek NPU etc.) | todo | |
| C9 | UI honesty (real backend chip) | todo | |

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

