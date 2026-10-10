# GPU acceleration: how to actually enable it

Status: **investigated, not yet enabled.** The shipped APK runs CPU-only.

## Why it is off today

`scripts/patch_native_llama.py` disables Vulkan. That was the right call to get a
*working* build, but the reasoning written into the script was wrong, and the
real cause is a one-line CI fix.

## The real root cause

`native_llama` vendors a complete `ggml/src/ggml-vulkan/` backend, sets
`GGML_VULKAN ON`, and links `vulkan`. It is genuinely buildable. Two errors were
blamed on the vendored tree; both trace to **one missing host tool: `glslc`**.

### Error 1 — `undefined symbol: ggml_backend_vk_reg`

`android/build.gradle.kts` hard-codes:

```
cppFlags("-std=c++17", "-DGGML_USE_VULKAN=1", "-DGGML_VULKAN_PERF_FA=0")
```

That `-DGGML_USE_VULKAN=1` makes `ggml-backend-reg.cpp` compile
`register_backend(ggml_backend_vk_reg())`. The Vulkan backend then needs to be
linked — and it is compiled by `ggml_add_backend(Vulkan)`, which requires
`glslc`:

```cmake
# ggml/src/ggml-vulkan/CMakeLists.txt line 9
find_package(Vulkan COMPONENTS glslc REQUIRED)
```

Without `glslc` the backend is not built, but the define is still set, so the
symbol is unresolved.

### Error 2 — `undefined symbol: flash_attn_f32_f16_f32_data`

The old script blamed this on "a vendored `ggml-cpu` with no flash-attention
kernels". That is false. Grep the vendored tree:

```bash
grep -rn "flash_attn_f32_f16_f32_data" ios/shared_cpp/ | wc -l   # -> 0
```

It appears **nowhere**, because it is not source. It is a **generated SPIR-V
shader blob**: `vulkan-shaders-gen` compiles the GLSL in
`ggml-vulkan/vulkan-shaders/` and emits a header of `uint64_t <name>_data[]`
arrays, one per shader. No `glslc` → no generated header → undefined symbol.

So both errors are the same bug wearing different hats.

## The fix

1. Install the shader compiler on the runner **before** the Flutter build:

   ```yaml
   - name: Install Vulkan shader compiler (glslc)
     run: sudo apt-get update && sudo apt-get install -y glslang-tools
   ```

2. Keep `GGML_VULKAN ON` in `CMakeLists.txt` and keep
   `-DGGML_USE_VULKAN=1` in `build.gradle.kts` (i.e. skip the patch script's
   Vulkan section — it must still not break anything else).

3. Verify after the build, by checking the APK actually contains the Vulkan
   backend:

   ```bash
   unzip -o -q out/localmind-release.apk lib/arm64-v8a/libllama.so -d /tmp/vk
   strings /tmp/vk/lib/arm64-v8a/libllama.so | grep -c vulkan   # want > 0
   ```

## Risks

- Vulkan needs a **device driver**. Many phones have one; some do not. Always
  keep the CPU fallback reachable (`n_gpu_layers = 0` must still work), and
  probe at startup with `ggml_backend_vk_reg` availability rather than assuming.
- `GGML_VULKAN_PERF_FA OFF` is already set, which is the conservative choice.
- Adds roughly 1–3 MB to the APK for the shader blobs.

## Do it on its own branch

Enabling GPU touches the build system, not Dart. Land it as its own commit so a
failure cannot block feature work, and keep the CPU-only build as the known-good
baseline.
