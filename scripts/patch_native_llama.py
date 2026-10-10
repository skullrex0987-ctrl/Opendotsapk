#!/usr/bin/env python3
"""Make native_llama 1.0.1 build on Android.

The published package ships an `ios/shared_cpp` tree that is shared by the
Android CMake config (android/src/main/cpp/CMakeLists.txt points at it via
../../../../ios/shared_cpp). That tree contains ggml-vulkan, but the ggml-cpu
half has no flash-attention kernels:

    ld.lld: error: undefined symbol: flash_attn_f32_f16_f32_data

`ggml-vulkan` references those symbols unconditionally, so with the vendored
subset the Vulkan backend can never link. The package also forces
`GGML_VULKAN=ON`, and its CMake then calls
`target_include_directories(ggml-vulkan ...)`, which errors outright if the
target does not exist.

So: turn Vulkan off, and guard the include block on the target existing.
Inference runs on the CPU backend, which is what a 0.5B Q4 model wants anyway.

Run once, right after `flutter pub get`, before the Gradle build.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

VULKAN_ON = 'set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan" FORCE)'
VULKAN_OFF = 'set(GGML_VULKAN OFF CACHE BOOL "Vulkan off: vendored ggml-cpu has no flash-attn kernels" FORCE)'

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


def main() -> int:
    # PUB_CACHE can point anywhere, and the package may land under a different
    # host directory than pub.dev, so glob for the CMakeLists rather than
    # assuming a layout.
    roots = [Path(os.environ["PUB_CACHE"])] if os.environ.get("PUB_CACHE") else []
    roots.append(Path.home() / ".pub-cache")
    roots.append(Path.cwd() / ".dart_tool")

    seen: list[Path] = []
    candidates: list[Path] = []
    for root in roots:
        if root in seen or not root.is_dir():
            continue
        seen.append(root)
        candidates.extend(sorted(
            root.glob("**/native_llama-*/android/src/main/cpp/CMakeLists.txt")))

    if not candidates:
        print("::error::native_llama CMakeLists not found; searched:")
        for root in seen:
            print("  - %s" % root)
            for entry in sorted(root.glob("**/native_llama*"))[:10]:
                print("      %s" % entry)
        return 1

    changed = []
    for cmake in candidates:
        text = original = cmake.read_text()

        if VULKAN_ON in text:
            text = text.replace(VULKAN_ON, VULKAN_OFF)
        if INCLUDE_BLOCK in text:
            text = text.replace(INCLUDE_BLOCK, GUARDED_BLOCK)
        elif "if(TARGET ggml-vulkan)" not in text:
            print("::error::unexpected ggml-vulkan include block in %s" % cmake)
            return 1

        if text != original:
            cmake.write_text(text)
            changed.append(str(cmake))
            print("patched %s" % cmake)

    if not changed:
        print("native_llama already patched (or nothing to do)")
    else:
        print("Vulkan disabled in %d file(s); inference runs on CPU" % len(changed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())