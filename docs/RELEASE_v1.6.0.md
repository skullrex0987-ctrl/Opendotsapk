# Release v1.6.0

Unreleased. This document is written before the tag exists, so it carries no
date, no APK size and no benchmark figures — those are added from the CI run when
the tag is pushed. The build that matters is the one the
[Build APK workflow](../.github/workflows/build-apk.yml) produces, and it is
gated on unit tests, 16 KB page alignment, the tag/version equality check, native
library presence and `apksigner` verification.

## Fixed

### Qwen3.5 0.8B could never be loaded as the chat model

Selection required `kind == ModelKind.llm`. Qwen3.5 is registered with
`ModelKind.vision` — vision is why it is listed at all — so it was rejected as a
chat candidate, the app silently fell back to a catalogue default the user had
never downloaded, and tapping **Load** reported "No chat model downloaded yet"
forever. The model you picked, however many times you tried.

The rule now lives on the pure model layer as
`ModelCatalog.isChatCapable(m) => m.kind == ModelKind.llm || m.isMultimodal`, so
it is unit-testable without `SharedPreferences` or a device. Covered by
`test/chat_model_selection_test.dart`.

- [x] `isChatCapable` accepts a multimodal model as the chat brain.
- [x] Every entry in `ModelCatalog.llms` is chat-capable (catches the next one).
- [x] Vision-only and embedding models are still rejected.
- [x] Qwen3.5 is offered in both the chat and the vision list.

### The architecture warning named the wrong model

The model-picker sheet read the catalogue default for the chat side of the
mismatch message, so a correctly configured pair still printed "Qwen2.5 0.5B
cannot use Qwen3.5" and the warning read as a bug rather than as guidance. It now
reads the selected chat model.

### Load no longer dies when the GPU refuses the model

A Vulkan init failure used to end at "the model will not load". `LlmService`
now retries once at zero GPU layers on the CPU — llama.cpp loads the same file
fine that way — and reports which backend actually ran (`vulkan` or `cpu`)
instead of the requested layer count.

### Load reports the real native error

`LlmService.lastLoadError` carries the plugin's own message, and the chat screen
shows that text rather than a generic failure, so an out-of-memory load, a
corrupt file and a broken driver stop looking identical. The reason is also
recorded in **Activity → Diagnostics**.

### A failed load no longer claims the model is in memory

`_isLoaded`, `_modelPath`, `_activeBackend` and `_gpuLayers` are cleared on every
failure path, including the exception path, so the "Currently in memory" line in
the model sheet cannot advertise a model that is not loaded.

### Every staggered entrance crashed on first paint

`FadeSlideIn` computed where the visible part of the animation starts as
`delay / total`, but clamped the **denominator** rather than the ratio:

```dart
delay.inMilliseconds / (total.inMilliseconds).clamp(0.0, 0.99)
```

`clamp` on an `int` returns an `int`, so the ratio was never bounded — a 240 ms
delay against a 300 ms duration produced `begin = 242.4` instead of `0.44`.
`Interval` asserts `begin <= 1.0`, so **every** `FadeSlideIn` with a non-zero
delay threw `Failed assertion: line 178 pos 12: 'begin <= 1.0'` while building
its frame. Any screen that staggered — Activity's timeline, Memory's cards,
Cloud's sections — would have failed on first paint, in debug and release
alike. Caught by `test/motion_test.dart`, not by a device.

The clamp now applies to the ratio, `total == 0` is treated as `begin = 0.0`,
and the arithmetic is pinned by three regression tests (overrun delay, zero
duration, and a staggered row that must end fully opaque).

### Undownloaded models were reported as installed

`probeFilePresence` assumed `FileStat.stat` throws for a missing path. It does
not — it returns a stat whose `type` is `FileSystemEntityType.notFound` and whose
`size` is `-1`. Reading that as "exists, length -1" made every model in the
catalogue that the user had *not* downloaded report as present, which is what
turned a missing download into a silent load failure. The type is now checked
explicitly. Pinned by `test/model_file_cache_test.dart`.

### Six silent `catch` blocks now log

Each of these swallowed the exception with a bare `catch (_) {}`, which is what
made the bugs above hard to see from the outside:

| Location | What was invisible |
|---|---|
| `ModelManager._deleteQuietly` | A `.part` that cannot be deleted (volume full) turns "clean restart" into "resume a corrupt file". |
| `ModelManager._readMeta` / `_writeMeta` | A lost validator sidecar makes the resume path look inexplicable. |
| `RouterService._probeConnectivity` | A failed DNS lookup is indistinguishable from being genuinely offline. |
| `SecureStore._readConfig` | A corrupt config blob makes a provider look like it ignored the base URL you typed. |
| `ToolPermissionStore` | "I allowed this tool and it still asks every time" had no visible cause. |
| `AgentOrchestrator` | A tool call that ran but left no Activity entry. |

## Added

### A design foundation: `AppTheme` and `AppMotion`

- `lib/core/theme/app_theme.dart` — one `ThemeData` for the app: seeded colour
  scheme with the brand indigo `#6366F1`, a cyan accent `#22D3EE` for
  AI-authored surfaces, stepped dark surfaces (`background` < `surface` <
  `surfaceHigh`, because shadows are invisible on near-black and elevation then
  carries no information), a tightened type scale, and component themes for
  cards, sheets, inputs, buttons, chips and scrollbars. 16 dp container radius,
  12 dp controls.
- `lib/core/theme/motion.dart` — one timing language: `AppMotion.standard` /
  `enter` / `exit` curves, 120/200/300/450 ms steps, `AppPageRoute` (fade plus a
  3 % rise) and `FadeSlideIn` for staggered entrances, built on
  `TweenAnimationBuilder` so there is no controller to leak.
- `LocalMindApp` now sets `theme: AppTheme.dark`, so the app has a single theme
  at its root instead of each screen carrying its own.

**Scope, stated plainly.** Both files are in place, wired at the app root, and
adopted by every screen and shared widget. All eleven screens now read
`Theme.of(context)` and the shared tokens rather than hand-picked colours; the
only literal `Color(0x…)` values left outside `lib/core/theme` are the two
brand gradient stops in `app.dart` and `settings_screen.dart`, which are the
gradient itself.

Motion is applied where it carries meaning — the shell, onboarding, the chat
status chip, the composer, and staggered entrances on the Activity timeline,
Memory cards and Cloud sections via a shared `staggerDelay(index)` that caps at
six steps so a long list animates in a wave instead of a queue. `AppPageRoute`
backs the pushed screens.

### Performance work on the model list

Every model screen asked `isInstalled` once per catalogue row on every build,
and each of those cost four platform-channel calls to resolve the documents
directory plus two `stat` calls. Now:

- the documents directory is resolved **once per process** and memoised;
- `probeFilePresence` performs **one** `stat` instead of `exists()` + `length()`;
- a TTL `FilePresenceCache` answers repeat questions, invalidated by the exact
  path that each download write, rename or delete touches;
- the correctness fix above (notFound vs. throw) landed in the same function.

## Changed

- [ ] `pubspec.yaml` version to `1.6.0+<n>` — required before the tag, or the
      version gate in CI fails the build.
- [x] Nothing else. No dependency moved, no database migration, no permission
      change. Existing installs update in place once the release keystore exists.

## Still open

Carried forward from [AUDIT_PROGRESS.md](AUDIT_PROGRESS.md); none of it is
claimed as fixed here.

- [ ] `AgentOrchestrator` has no call site in the chat screen.
- [ ] The seven unimplemented tools (`send_sms`, `create_calendar_event`,
      `add_contact`, `set_alarm`, `open_app`, `create_note`, `read_notes`) need
      system Intents. They stay hidden from the model until they work.
- [ ] `libonnxruntime.so` is 4 KB-aligned (`0x1000`); the pub package is frozen
      at 1.4.1. See [PAGE_ALIGNMENT.md](PAGE_ALIGNMENT.md).
- [ ] No release keystore, so builds are debug-signed and not updatable. See
      [RELEASE_SIGNING.md](RELEASE_SIGNING.md).
- [ ] Model downloads still die if Android suspends the app — they resume, but
      there is no foreground service.
- [ ] Nothing in this release has been run on a physical device. See
      [DEVICE_TEST_CHECKLIST.md](DEVICE_TEST_CHECKLIST.md).

## Verify before tagging

```bash
flutter test                                  # 244 unit and widget tests
python3 scripts/check_page_alignment.py out/localmind-1.6.0.apk
```

Then tag `v1.6.0` and let the workflow check the rest: version equality, native
library presence, mtmd/CLIP symbols, the Vulkan entry point, `apksigner`, and a
`SHA256SUMS` file.
