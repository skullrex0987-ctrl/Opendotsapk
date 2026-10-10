# GPU acceleration

Status: **enabled and shipping** since v1.2.0.

This document started as an investigation titled "how to actually enable it". It is
kept, rewritten, because the reasoning that got written down the first time was
wrong in two places, and both corrections matter.

## What ships

`libggml-vulkan.so`, ~47 MB, built from the `ggml-vulkan` backend vendored inside
`native_llama`. Verified in the released APK:

```
T ggml_backend_vk_reg                  # the registration entry point
NEEDED  libvulkan.so                   # the Android platform loader
```

The size is the compiled SPIR-V blobs: 153 compute shaders, each generated once
per supported type and quantization variant. They are generated at build time,
not checked in.

> **Correction to the original note.** It predicted "roughly 1–3 MB". The real
> figure is ~47 MB, which took the APK from 36 MB to 52 MB. Worth knowing before
> enabling this on a project where download size matters.

## The two link failures, and their single cause

Both historical errors were symptoms of one missing tool.

### Error 1 — `undefined symbol: ggml_backend_vk_reg`

`android/build.gradle.kts` hard-codes:

```
cppFlags("-std=c++17", "-DGGML_USE_VULKAN=1", "-DGGML_VULKAN_PERF_FA=0")
```

That define makes `ggml-backend-reg.cpp` compile
`register_backend(ggml_backend_vk_reg())`. If the Vulkan backend library is not
actually linked, the symbol has no definition.

### Error 2 — `undefined symbol: flash_attn_f32_f16_f32_data`

The old note called this "a vendored `ggml-cpu` with no flash-attention kernels".
That was false, and the correction is the key to the whole problem:

```bash
grep -rn "flash_attn_f32_f16_f32_data" ios/shared_cpp/ | wc -l   # -> 0
```

It appears **nowhere in the source**, because it is not source. It is a generated
SPIR-V blob: `vulkan-shaders-gen` compiles the GLSL in `ggml-vulkan/vulkan-shaders/`
and emits a header of `uint64_t <name>_data[]` arrays. No generator run, no blobs.

### The shared cause

`ggml-vulkan/CMakeLists.txt` line 9:

```cmake
find_package(Vulkan COMPONENTS glslc REQUIRED)
```

`glslc` is the GLSL→SPIR-V compiler. Without it the `ggml-vulkan` target is never
created, so *neither* symbol is defined. One missing host tool, two confusing
error messages, in two different places.

## The fix, as implemented

1. Install the shader compiler on the runner before the Flutter build:

   ```yaml
   - name: Install Vulkan shader compiler
     run: |
       sudo apt-get update -qq
       sudo apt-get install -y --no-install-recommends \
         glslc spirv-tools libvulkan-dev vulkan-tools
   ```

   `glslc` is packaged on Ubuntu (source package `shaderc`) — no Vulkan SDK
   download is needed. The original note suggested `glslang-tools`, which provides
   `glslangValidator`, not `glslc`; that would not have satisfied
   `find_package(Vulkan COMPONENTS glslc)`.

2. `scripts/patch_native_llama.py` now detects `glslc` instead of blanket-disabling
   Vulkan: present → keep the Gradle define and `GGML_VULKAN ON`; absent → strip
   the define and force `GGML_VULKAN OFF` so the build degrades to CPU-only rather
   than failing to link. It still guards `target_include_directories(ggml-vulkan …)`,
   which errors outright when the target does not exist.

3. CI verifies the APK afterwards — `libggml-vulkan.so` present, and
   `ggml_backend_vk_reg` exported — and warns loudly if not. A CPU-only APK still
   works, so without a check this would regress unnoticed.

## Runtime behaviour

llama.cpp decides per device, which is what lets a single APK serve many phones:

- `ggml_backend_load_all()` registers the Vulkan backend only if it enumerates a
  usable device. No Vulkan driver, or one that fails to initialise, means the CPU
  backend handles everything. `n_gpu_layers = 0` remains fully functional.
- `n_gpu_layers` is passed per launch, so the layer count is a **policy** decision
  rather than a build decision. See `lib/data/services/gpu_service.dart`.

**Dependency note.** The native libraries carry a hard `NEEDED` on
`libvulkan.so`, including `libnative_llama.so` itself. This is safe at
`minSdk 28` because Android 9 guarantees the platform Vulkan *loader* is present.
It is the absence of a *driver*, not of the loader, that triggers the CPU
fallback. On an older minSdk this would risk the dynamic linker failing to load
the native libraries at all — which is a crash, not a fallback — so do not lower
minSdk without revisiting this.

## When the GPU is the wrong choice

Token generation is memory-bandwidth-bound. A mobile GPU with a narrow memory bus
does not reliably beat well-vectorised NEON kernels, and on many midrange Mali
parts the CPU is genuinely faster. The original note's assumption that enabling
Vulkan is a straight win for everyone is not true.

So offload is opt-in with a measurement, not a silent default:

| Condition | Default |
|---|---|
| Midrange Mali (not Immortalis, not G715/G720) | CPU |
| `isLowRamDevice`, or under 4 GB RAM | CPU |
| Emulator (`goldfish`/`ranchu`/`sdk_gphone`) | CPU |
| Other known GPU, sufficient RAM | GPU, all layers |
| Unrecognised device | GPU attempted; falls back if the driver refuses |

Settings → Performance shows the detection result, allows Auto/GPU/CPU, and runs a
throughput benchmark so the decision rests on the user's own hardware.

Offload is fixed when the model loads, so changing it prompts a reload.

## Neural accelerators

Not used, and the app says so rather than implying otherwise. Each phone NPU needs
a vendor-specific runtime — Qualcomm QNN/Hexagon, MediaTek NeuroPilot, Samsung ENN,
Google Edge TPU, Huawei Da Vinci — with different SDKs, licences and quantization
requirements, and no common build target. There is no portable NPU backend for
llama.cpp, so no single build reaches them. `GpuService` detects and names the NPU;
the Performance screen states plainly that it is not being used.

## Verifying a build

```bash
unzip -l localmind-release.apk | grep libggml-vulkan        # shipped?
unzip -o -q localmind-release.apk "lib/arm64-v8a/libggml-vulkan.so" -d /tmp/v
nm -D --defined-only /tmp/v/lib/arm64-v8a/libggml-vulkan.so | grep vk_reg
readelf -d /tmp/v/lib/arm64-v8a/libggml-vulkan.so | grep vulkan
```
