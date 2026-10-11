# ADR — native binding: patched pub package vs owned pinned wrapper

Status: **Proposed** (decision input for audit tasks **C5 / C7**)
Date: 2026-10-11

## Context

LocalMind runs inference through `native_llama` 1.0.1, a pub package that vendors a
whole `llama.cpp` tree. `pubspec.yaml` records why it was chosen: it is the only
candidate that ships `tools/mtmd` (mmproj vision) *and* a complete
`ggml/src/ggml-vulkan` backend. The Android plugin's
`android/build.gradle.kts` hard-codes `-DGGML_USE_VULKAN=1` and its
`android/src/main/cpp/CMakeLists.txt` forces `GGML_VULKAN ON`, so the package
does not build cleanly out of the box. `scripts/patch_native_llama.py` repairs
this **at build time by editing files inside the pub cache** (it globs
`**/native_llama-*/android` under `PUB_CACHE`, `~/.pub-cache`, and `.dart_tool`),
toggling `GGML_VULKAN` and the Gradle define depending on whether `glslc` is
present, and wrapping the `target_include_directories(ggml-vulkan …)` block in
`if(TARGET ggml-vulkan)`.

Two audit asks force a decision about whether that patching approach is where we
want to be:

- **C5** wants an `InferenceBackend` abstraction (a stable seam over whatever runs
  the model).
- **C7** wants **Adreno OpenCL** and **Qualcomm Hexagon NPU** backends.

That last one is the crux: it assumes the vendored `ggml` can be made to produce
those backends. This ADR checks that assumption against the actual package.

Constraints that bound the options (from `docs/AUDIT_PROGRESS.md`): no Flutter SDK
on the build host, ~350 MB RAM, ~2.9 GB disk, so **CI is the only build path**
and a full APK build already costs ~8–11 min.

---

## Investigation: what is actually inside `native_llama` 1.0.1

Method: downloaded `https://pub.dev/api/archives/native_llama-1.0.1.tar.gz`
(`native_llama` 1.0.1 was published **2026-04-28**,
<https://pub.dev/api/packages/native_llama>), extracted it, and inspected the
vendored tree.

**1. The vendored llama.cpp revision is current, not stale.** The
`ggml/CMakeLists.txt` declares `GGML_VERSION_MAJOR 0 / MINOR 9 / PATCH 11` —
i.e. **ggml 0.9.11**. Upstream bumped to 0.9.11 on **2026-04-02**
(<https://github.com/ggml-org/llama.cpp/commit/bc07d559224260f65f40595121d9e2ebe60ee99e>),
consistent with the package's late-April publish date. This matters because the
audit's target backends are *recent*: `ggml-hexagon` was merged upstream
**2025-10-22** (<https://github.com/ggml-org/llama.cpp/pull/16547>, "Add
experimental ggml-hexagon backend for the Hexagon NPU"). A ggml 0.9.11 tree is
therefore **new enough to contain both `ggml-hexagon` and the Adreno-targeted
`ggml-opencl` backend upstream**.

**2. …but the source for those two backends has been deleted from the package.**
The vendored tree's `ggml/src/` contains exactly these subdirectories:

```
ggml-cpu   ggml-hip   ggml-metal   ggml-virtgpu   ggml-vulkan   ggml-zdnn   ggml-zendnn
```

There is **no `ggml/src/ggml-opencl/` and no `ggml/src/ggml-hexagon/`**. Yet the
package still *references* them everywhere:

- `ggml/CMakeLists.txt` defines the options `GGML_OPENCL` (and
  `GGML_OPENCL_USE_ADRENO_KERNELS`) and `GGML_HEXAGON`.
- `ggml/include/ggml-opencl.h` and `ggml/include/ggml-hexagon.h` are present.
- `ggml/src/ggml-backend-reg.cpp` includes both headers and calls
  `ggml_backend_opencl_reg()` / `ggml_backend_hexagon_reg()`.
- `ggml/src/CMakeLists.txt` literally calls `ggml_add_backend(OpenCL)` and
  `ggml_add_backend(Hexagon)`.

`ggml_add_backend` does `add_subdirectory(ggml-opencl)` / `(ggml-hexagon)`. So
flipping `GGML_OPENCL=ON` or `GGML_HEXAGON=ON` makes CMake try to descend into a
directory that does not exist — a **configure-time failure**, not a missing
feature. The package's own `CHANGELOG.md` explains the cause: 1.0.1 introduced "a
highly aggressive `.pubignore` to bypass pub.dev's 100MB limit by stripping
unused server/desktop GPU backends (CUDA, SYCL, etc.)". CUDA, SYCL, OpenCL and
Hexagon are all gone from the published archive; only the CPU and Vulkan source
(as the app's doc notes) needed for the shipped product survive.

**3. Which backends actually exist and build.**
`ggml/src/CMakeLists.txt` ends with `ggml_add_backend(CPU)` plus a list including
BLAS, CANN, CUDA, HIP, METAL, MUSA, RPC, VirtGPU, SYCL, Vulkan, WebGPU, zDNN,
OpenCL, Hexagon, ZenDNN, OpenVINO — but only the ones whose source survives can
be enabled. For Android arm64 the realisable set is **CPU** (enabled by default)
and **Vulkan** (which the app already enables and ships at ~47 MB per
`docs/GPU_ACCELERATION.md`). Everything else is either irrelevant to Android
(hip/metal/zdnn/zendnn) or stripped (opencl/hexagon/cuda/sycl).

**4. The patching surface, concretely.** The script rewrites exactly two strings
in two pub-cache files:

- `android/src/main/cpp/CMakeLists.txt` line 11,
  `set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan" FORCE)` → the `OFF` variant, and
  guards the `target_include_directories(ggml-vulkan …)` block (lines 44–47).
  If neither the `ON`/`OFF` string nor an `if(TARGET ggml-vulkan)` guard is found,
  the script calls `raise SystemExit("::error::unrecognised ggml-vulkan block …")`.
- `android/build.gradle.kts`, toggling the literal `-DGGML_USE_VULKAN=1` in
  `cppFlags`/`arguments`.

**5. Additional fragility found while reading the CMakeLists.** The Android
plugin's CMakeLists fetches two host dependencies at configure time with
**unpinned** refs:

```cmake
FetchContent_Declare(VulkanHeaders GIT_REPOSITORY https://github.com/KhronosGroup/Vulkan-Headers.git GIT_TAG main)
FetchContent_Declare(SPIRVHeaders   GIT_REPOSITORY https://github.com/KhronosGroup/SPIRV-Headers.git   GIT_TAG main)
```

`GIT_TAG main` means the build is **not reproducible**: a header change upstream
can break CI with no local change.

---

## Options

**Option A — continue as-is: patch the vendored `ggml` inside the `native_llama`
pub package at build time.**
`scripts/patch_native_llama.py` stays the mechanism; every enabled backend must be
reachable by editing the package's CMake/gradle in the pub cache.

**Option B — replace `native_llama` with a thin, first-party JNI/FFI wrapper over
a PINNED upstream `llama.cpp` release.**
Bring `llama.cpp` (plus `tools/mtmd`) into the repo pinned to a tag/commit; write
our own small Kotlin plugin + `native-lib.cpp` (the Dart/MethodChannel surface can
stay identical, so callers do not change); compile exactly the backends we want.

---

## Comparison

### Backend coverage (the C7 question — decisive)

- **A cannot deliver C7.** Adreno OpenCL and Hexagon NPU both require source that
  the published package deletes (§2). You cannot enable them with a flag; you
  would have to re-vendor the missing `ggml-opencl` / `ggml-hexagon` trees from
  upstream — which is *option B's work*, performed as a hack inside the pub
  cache. So the audit's C7 goal is **unreachable under A** without turning A into
  B.
- **B delivers C7 by construction** — pinned upstream `llama.cpp` at ≥ the
  revision that contains `ggml-hexagon` (merged 2025-10-22) and `ggml-opencl`, with
  the CMake flags under our control. Cost/risk of those backends is then a
  separate, honest question (Hexagon needs the Hexagon SDK + a Docker toolchain,
  and is upstream-"experimental"; OpenCL needs the OpenCL loader/kernel blobs at
  build), but at least the option exists.

### Build fragility

- **A** depends on: the pub cache being freshly extracted (nothing else re-extracts
  it), the exact replace-strings still being present, the glob finding the right
  directory, and `glslc` being installed on the runner. Any `flutter pub upgrade`,
  cache clear, or `native_llama` patch release can silently move the goalposts;
  the failure modes range from a hard `SystemExit` (good) to a CPU-only APK that
  still builds (bad — GPU regresses silently, which is why `docs/GPU_ACCELERATION.md`
  added an APK verification step).
- **A** is also non-reproducible through the unpinned `GIT_TAG main` fetches (§5).
- **B** is a normal source build: pinned revision, no mutation of third-party
  caches, standard CMake options. The fragility does not vanish (native builds are
  never free) but it becomes *ours and versioned*, which is the point.

### Upgrade path

- **A:** "upgrade" means bumping the pub version and hoping the patch strings
  survived. There is no supported way to pin the vendored `llama.cpp` revision
  independently of the package, and no way to pull an upstream fix for just
  `ggml` without waiting for the package author.
- **B:** bump the pinned `llama.cpp` tag/commit in one place, rebuild, test. We
  can take an upstream fix the day it lands. We also stop being blocked when a
  package maintainer strips a backend we need.

### CI cost

- **Both** compile `llama.cpp` from source for `arm64-v8a` inside the same Gradle
  build, so the incremental CI time is broadly similar; the source of the C++
  differs, not the amount of it.
- **B adds**: we now own the native compile configuration, so a broken
  `llama.cpp` bump is our CI to debug. **A adds**: the extra `patch_native_llama.py`
  step before every build, plus the chance of a silent CPU-only regression that
  the existing APK check must catch.
- Net: roughly a wash on minutes; B shifts effort from "debug the patcher when a
  pub refresh wipes it" to "own a pinned build". For a project whose only build
  path is CI, *determinism* is worth more than a warm-and-fuzzy dependency.

### Maintenance burden

- **A:** two external things to watch that are not ours — the pub package (its
  version, its `.pubignore`, its vendored revision) and the patch script's string
  contracts. Every dependency bump is a small audit.
- **B:** one external thing to watch — upstream `llama.cpp` — plus our own JNI
  surface. The app already carries `llama.cpp`-specific code (`native-lib.cpp` is
  the wrapper; `pubspec.yaml` documents the whole Vulkan/glslc story), so the
  "you own it" cost is largely already paid; B just relocates it into the repo
  where it is visible and testable.

### What would break

- **A breaks when:** someone runs `flutter pub get`/`pub upgrade` and forgets the
  patch step (GPU silently gone); `native_llama` releases a version whose CMake
  no longer contains the expected strings (hard configure error); pub.dev's
  100 MB stripping removes something else we rely on; Vulkan-Headers/SPIRV-Headers
  `main` moves.
- **B breaks when:** an upstream `llama.cpp` bump changes an API our
  `native-lib.cpp` uses (compile error — loud and fixable); or we mis-configure a
  backend (our own CMake, our own fault, visible in the repo).
- The one thing **B would lose if done carelessly:** `native_llama`'s *packaged*
  Kotlin/Dart API and its mtmd wiring. Mitigation: keep the Dart-facing method
  surface byte-for-byte, and vendor `tools/mtmd` at the same pinned revision.
  The current repo already proves this is tractable — the package itself builds
  Android by `add_subdirectory`-ing the *iOS* `shared_cpp` tree, so the tree is
  already a single shared source root.

---

## Decision (recommendation)

**Adopt Option B, but phased, and not as a big-bang rewrite.**

1. **Now:** keep Option A working. It ships Vulkan today and the patch script is
   tested. Treat the current state as the bridge, not the destination.
2. **Before C7 is attempted:** do not try to bolt OpenCL/Hexagon onto the patched
   pub cache — that is the unreachable path from §2 and would be the worst of
   both worlds (pub-cache hacks *plus* re-vendored source). Instead stand up B:
   vendor `llama.cpp` (with `tools/mtmd`) at a **pinned revision ≥ the one
   containing `ggml-hexagon`**, and port the existing `native-lib.cpp` bridge to
   it behind the C5 `InferenceBackend` seam. Because C5 wants that seam anyway,
   the migration cost is shared with work already planned.
3. **Pin everything:** the `llama.cpp` commit, and Vulkan/SPIRV headers (replace
   `GIT_TAG main` with pinned tags). Reproducibility is the main prize.

If the project decides C7 (NPU/OpenCL) is out of scope for this cycle, then A is
an acceptable holding pattern — **with the caveat that it is a holding pattern
only**: the day either backend is wanted, A stops being able to help and B begins.

A third, narrowly-scoped option — **fork the `native_llama` package** (vendor its
`android/` and `ios/shared_cpp/` into this repo and stop using the pub one) — is
worth noting as a lower-effort stepping stone to B: it removes the pub-cache
patching immediately, keeps the existing Kotlin/Dart API, and still lets us add
the stripped backends. Its drawback is that we inherit the package author's tree
and must refresh it by hand; it is best used as the first commit of B, not as an
end state.

---

## Consequences

**Positive**

- The audit's C7 backends become *possible* (they are impossible under A as
  published).
- Builds become reproducible: pinned `llama.cpp` and pinned headers, no mutation
  of a third-party cache, no dependence on a package author's `.pubignore`.
- Upgrade path is a one-line revision bump we control; upstream fixes land on our
  schedule.
- The `InferenceBackend` seam (C5) and the native binding converge onto one owned,
  visible component instead of a patcher script plus an opaque package.

**Negative / accepted costs**

- We take on ownership of the JNI wrapper and the native CMake configuration. That
  is real, ongoing work — and CI debugging of native builds is painful on this
  host (no local Flutter, tiny RAM/disk).
- Vendor-runtime reach (Adreno OpenCL, Hexagon) still carries its own external
  burdens: the Hexagon path needs the Hexagon SDK / a Docker toolchain and is
  upstream-experimental; OpenCL needs loader/kernel blobs at build time. Choosing
  B only removes the *package* blocker, not those.
- Migration is a build-system change, so it must be validated by a green CI APK +
  the existing "is `libggml-vulkan.so` present and is `ggml_backend_vk_reg`
  exported" check, ideally with a device smoke test per the project's device
  checklist.

**Follow-ups**

- Add a CI assertion that the pinned `llama.cpp` revision is ≥ the known
  `ggml-hexagon` merge so the C7 prerequisite can never silently regress.
- Keep the `readelf`/`nm` APK verification from `docs/GPU_ACCELERATION.md`; extend
  it to any newly enabled backend `.so`.
- Record the chosen `llama.cpp` revision and header pins in this ADR (or a
  successor) once selected.
