#!/usr/bin/env python3
"""Make native_llama 1.0.1 build on Android.

The package forces Vulkan on from two places, and the ggml tree it vendors
cannot support it:

1. `android/build.gradle.kts` hard-codes
       cppFlags("-std=c++17", "-DGGML_USE_VULKAN=1", "-DGGML_VULKAN_PERF_FA=0")
   so `ggml-backend-reg.cpp` compiles the `register_backend(ggml_backend_vk_reg())`
   call even when no Vulkan backend is linked:

       ld.lld: error: undefined symbol: ggml_backend_vk_reg

2. `android/src/main/cpp/CMakeLists.txt` does `set(GGML_VULKAN ON ... FORCE)`.
   With Vulkan actually built, `ggml-vulkan` then references flash-attention
   kernels that the vendored `ggml-cpu` subset does not contain:

       ld.lld: error: undefined symbol: flash_attn_f32_f16_f32_data

So strip the Gradle-side define, switch the CMake option off, and guard the
`target_include_directories(ggml-vulkan ...)` call, which errors outright when
the target no longer exists.

Inference then runs on llama.cpp's CPU backend, which is what the 0.5B-class
models this app ships want anyway.

Run once, after `flutter pub get` and before the Gradle build.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# ---------------------------------------------------------------- CMakeLists

CMAKE_VULKAN_ON = 'set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan" FORCE)'
CMAKE_VULKAN_OFF = (
    'set(GGML_VULKAN OFF CACHE BOOL '
    '"off: vendored ggml-cpu has no flash-attn kernels" FORCE)'
)

CMAKE_INCLUDE_BLOCK = """target_include_directories(ggml-vulkan PRIVATE
    "${vulkanheaders_SOURCE_DIR}/include"
    "${spirvheaders_SOURCE_DIR}/include"
)"""

CMAKE_GUARDED_BLOCK = """if(TARGET ggml-vulkan)
    target_include_directories(ggml-vulkan PRIVATE
        "${vulkanheaders_SOURCE_DIR}/include"
        "${spirvheaders_SOURCE_DIR}/include"
    )
endif()"""

# ------------------------------------------------------------- build.gradle

GRADLE_FLAG = "-DGGML_USE_VULKAN=1"


def patch_cmake(path: Path) -> bool:
    original = text = path.read_text()

    if CMAKE_VULKAN_ON in text:
        text = text.replace(CMAKE_VULKAN_ON, CMAKE_VULKAN_OFF)

    if CMAKE_INCLUDE_BLOCK in text:
        text = text.replace(CMAKE_INCLUDE_BLOCK, CMAKE_GUARDED_BLOCK)
    elif "if(TARGET ggml-vulkan)" not in text:
        raise SystemExit("::error::unrecognised ggml-vulkan block in %s" % path)

    if text == original:
        return False
    path.write_text(text)
    return True


def patch_gradle(path: Path) -> bool:
    original = text = path.read_text()
    kept = [ln for ln in text.splitlines(keepends=True) if GRADLE_FLAG not in ln]
    text = "".join(kept)
    if text == original:
        return False
    path.write_text(text)
    return True


def main() -> int:
    roots: list[Path] = []
    if os.environ.get("PUB_CACHE"):
        roots.append(Path(os.environ["PUB_CACHE"]))
    roots.append(Path.home() / ".pub-cache")
    roots.append(Path.cwd() / ".dart_tool")

    seen: set[Path] = set()
    bases: list[Path] = []
    for root in roots:
        if root in seen or not root.is_dir():
            continue
        seen.add(root)
        bases.extend(sorted(root.glob("**/native_llama-*/android")))

    if not bases:
        print("::error::native_llama not found; searched:")
        for root in seen:
            print("  - %s" % root)
        return 1

    patched = 0
    for base in bases:
        cmake = base / "src/main/cpp/CMakeLists.txt"
        gradle = base / "build.gradle.kts"

        if cmake.is_file() and patch_cmake(cmake):
            patched += 1
            print("patched %s (GGML_VULKAN=OFF, include guarded)" % cmake)

        if gradle.is_file() and patch_gradle(gradle):
            patched += 1
            print("patched %s (dropped %s)" % (gradle, GRADLE_FLAG))

    if patched == 0:
        print("native_llama already patched; nothing to do")
    else:
        print("Vulkan disabled in %d file(s); inference runs on CPU" % patched)
    return 0


if __name__ == "__main__":
    sys.exit(main())