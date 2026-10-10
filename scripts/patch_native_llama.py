#!/usr/bin/env python3
"""Make native_llama 1.0.1 build on Android.

The published package ships an `ios/shared_cpp` tree that the Android CMake
config reuses (android/src/main/cpp/CMakeLists.txt reaches it via
../../../../ios/shared_cpp). That tree contains ggml-vulkan, but the ggml-cpu
half has no flash-attention kernels:

    ld.lld: error: undefined symbol: flash_attn_f32_f16_f32_data

so the Vulkan backend can never link against it. Three separate places force
Vulkan on, and all of them have to go or the build fails at a different symbol
each time:

  1. CMakeLists.txt          set(GGML_VULKAN ON ... FORCE)
                              target_include_directories(ggml-vulkan ...)  <- errors
                                                            when the target is absent
  2. android/build.gradle.kts  cppFlags/arguments "-DGGML_USE_VULKAN=1"

Leaving (2) in place produces a *different* failure after (1) is fixed:
`ggml-backend-reg.cpp` is still compiled with GGML_USE_VULKAN defined, so it
emits a call to `ggml_backend_vk_reg`, which nothing defines:

    ld.lld: error: undefined symbol: ggml_backend_vk_reg

Inference then runs on the CPU backend, which is what a 0.5B Q4 model wants
anyway. Run once, right after `flutter pub get`, before the Gradle build.
Idempotent: a second run reports "nothing to do".
"""

from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

# 1. CMake: stop forcing Vulkan, and guard the include block on the target.
VULKAN_ON = 'set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan" FORCE)'
VULKAN_OFF = (
    'set(GGML_VULKAN OFF CACHE BOOL '
    '"Vulkan off: vendored ggml-cpu has no flash-attn kernels" FORCE)'
)

INCLUDE_BLOCK = """target_include_directories(ggml-vulkan PRIVATE
    "${vulkanheaders_SOURCE_DIR}/include"
    "${spirvheaders_SOURCE_DIR}/include"
)"""

GUARDED_BLOCK = """if(TARGET ggml-vulkan)
    target_include_directories(ggml-vulkan PRIVATE
        "${vulkanheaders_SOURCE_DIR}/include"
        "${spirvheaders_SOURCE_DIR}/include"
    )
endif()"""

# 2. Gradle: strip the compile flags that would re-enable GGML_USE_VULKAN in
#    C++ land. Kotlin source sets do not need Vulkan when the C++ side is off.
VULKAN_CPPFLAG = re.compile(
    r'^\s*"-DGGML_(?:USE_)?VULKAN[A-Z_]*=[^"]*",?\s*\n', re.MULTILINE
)


def patch_cmake(text: str) -> str:
    text = text.replace(VULKAN_ON, VULKAN_OFF)
    if INCLUDE_BLOCK in text:
        text = text.replace(INCLUDE_BLOCK, GUARDED_BLOCK)
    return text


def patch_gradle(text: str) -> str:
    # "-DGGML_USE_VULKAN=1" / "-DGGML_VULKAN_PERF_FA=0" on their own lines.
    return VULKAN_CPPFLAG.sub("", text)


def package_roots() -> list[Path]:
    """Where pub may have unpacked native_llama.

    PUB_CACHE can point anywhere and the host directory is not always
    pub.dev, so glob rather than assume a layout.
    """
    roots: list[Path] = []
    env = os.environ.get("PUB_CACHE")
    if env:
        roots.append(Path(env))
    roots.append(Path.home() / ".pub-cache")
    roots.append(Path.cwd() / ".dart_tool")

    found: list[Path] = []
    for root in roots:
        if not root.is_dir():
            continue
        for cmake in sorted(root.glob("**/native_llama-*/android/src/main/cpp/CMakeLists.txt")):
            # <pkg>/android/src/main/cpp/CMakeLists.txt -> parents[4] == <pkg>
            pkg = cmake.parents[4]
            if pkg.is_dir() and pkg not in found:
                found.append(pkg)
    return found


def main() -> int:
    packages = package_roots()
    if not packages:
        print("::error::native_llama not found; searched PUB_CACHE, ~/.pub-cache, .dart_tool")
        return 1

    changed = 0
    seen = 0
    for pkg in packages:
        for rel, patcher in (
            ("android/src/main/cpp/CMakeLists.txt", patch_cmake),
            ("android/build.gradle.kts", patch_gradle),
            ("android/build.gradle", patch_gradle),
        ):
            target = pkg / rel
            if not target.is_file():
                continue
            original = target.read_text()
            patched = patcher(original)
            seen += 1
            if patched != original:
                if not os.access(target, os.W_OK):
                    print("::error::%s is not writable (read-only pub cache?)" % target)
                    return 1
                shutil.copymode(target, target)
                target.write_text(patched)
                print("patched %s" % rel)
                changed += 1
            else:
                print("no change needed in %s" % rel)

    if seen == 0:
        print("::error::found native_llama but none of the files to patch exist")
        return 1
    if changed:
        print("Vulkan disabled in %d file(s); inference runs on the CPU backend" % changed)
    else:
        print("native_llama already patched (%d file(s) checked, nothing to do)" % seen)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())