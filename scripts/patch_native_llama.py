#!/usr/bin/env python3
"""Make native_llama 1.0.1 build on Android — with GPU acceleration when possible.

## Background

`native_llama` vendors a complete `ggml-vulkan` backend (153 compute shaders plus
the `vulkan-shaders-gen` host tool that turns them into SPIR-V blobs at build
time). Two things stop that backend from working out of the box:

1.  `android/build.gradle.kts` hard-codes `-DGGML_USE_VULKAN=1` in `cppFlags`, so
    `ggml-backend-reg.cpp` compiles a `register_backend(ggml_backend_vk_reg())`
    call. If the Vulkan backend is not actually linked, the result is

        ld.lld: error: undefined symbol: ggml_backend_vk_reg

2.  `ggml-vulkan/CMakeLists.txt` opens with

        find_package(Vulkan COMPONENTS glslc REQUIRED)

    `glslc` is the GLSL→SPIR-V shader compiler. Without it the backend target is
    never created, and the flash-attention kernels it references — which exist
    only as *generated* SPIR-V blobs, e.g. `flash_attn_f32_f16_f32_data` — stay
    undefined, giving the second confusing link error.

Both failures have the same single cause: **glslc is missing**. So this script
does not blanket-disable Vulkan; it decides based on whether the shader compiler
is actually available.

## Modes

*   **glslc found** — leave the Gradle define `-DGGML_USE_VULKAN=1` in place,
    force `GGML_VULKAN ON`, and guard the `target_include_directories` call so it
    only runs when the target exists. The APK then ships GPU support.

    This is safe to distribute broadly: `ggml_backend_load_all()` registers the
    Vulkan backend only if a usable Vulkan device is found, and llama.cpp falls
    back to the CPU otherwise. A phone with no Vulkan driver — or with a broken
    one — simply runs on the CPU. That runtime fallback is what lets a single
    APK serve "almost all phones" rather than needing per-GPU builds.

*   **glslc missing** — strip the Gradle define and force `GGML_VULKAN OFF`, so
    the app builds CPU-only instead of failing to link.

Usage:
    python3 scripts/patch_native_llama.py            # auto-detect
    python3 scripts/patch_native_llama.py --cpu      # force CPU-only
    python3 scripts/patch_native_llama.py --require-gpu  # fail if glslc absent
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

# ---------------------------------------------------------------- CMakeLists

CMAKE_VULKAN_ON = 'set(GGML_VULKAN ON CACHE BOOL "Enable Vulkan" FORCE)'

CMAKE_VULKAN_OFF = (
    'set(GGML_VULKAN OFF CACHE BOOL '
    '"off: no glslc shader compiler on this host" FORCE)'
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


def glslc_path() -> str | None:
    """Locate glslc, including inside a LunarG Vulkan SDK if one is present."""
    found = shutil.which("glslc")
    if found:
        return found

    for var in ("VULKAN_SDK", "VULKAN_SDK_ROOT"):
        root = os.environ.get(var)
        if root:
            candidate = Path(root) / "bin" / "glslc"
            if candidate.is_file():
                return str(candidate)

    # Common install locations used by the distro package.
    for candidate in (
        Path("/usr/bin/glslc"),
        Path("/usr/local/bin/glslc"),
    ):
        if candidate.is_file():
            return str(candidate)

    return None


def patch_cmake(path: Path, enable_gpu: bool) -> bool:
    original = text = path.read_text()

    if enable_gpu:
        if CMAKE_VULKAN_OFF in text:
            text = text.replace(CMAKE_VULKAN_OFF, CMAKE_VULKAN_ON)
    else:
        if CMAKE_VULKAN_ON in text:
            text = text.replace(CMAKE_VULKAN_ON, CMAKE_VULKAN_OFF)

    # Guard the include-directories call either way: it is fatal when the
    # ggml-vulkan target was not created, which is exactly what happens on the
    # CPU-only path.
    if CMAKE_INCLUDE_BLOCK in text:
        text = text.replace(CMAKE_INCLUDE_BLOCK, CMAKE_GUARDED_BLOCK)
    elif "if(TARGET ggml-vulkan)" not in text:
        raise SystemExit("::error::unrecognised ggml-vulkan block in %s" % path)

    if text == original:
        return False
    path.write_text(text)
    return True


def patch_gradle(path: Path, enable_gpu: bool) -> bool:
    original = text = path.read_text()
    lines = text.splitlines(keepends=True)

    if enable_gpu:
        # The define must be present, or the backend is compiled but never
        # registered with ggml's backend registry.
        if GRADLE_FLAG in text:
            return False
        out: list[str] = []
        added = False
        for ln in lines:
            out.append(ln)
            if not added and "cppFlags" in ln:
                indent = ln[: len(ln) - len(ln.lstrip())] + "    "
                if ln.rstrip().endswith(")"):
                    out[-1] = ln.replace(")", '"%s")\n' % GRADLE_FLAG)
                else:
                    out.append('%s"%s",\n' % (indent, GRADLE_FLAG))
                added = True
        if not added:
            return False
        text = "".join(out)
    else:
        text = "".join(ln for ln in lines if GRADLE_FLAG not in ln)

    if text == original:
        return False
    path.write_text(text)
    return True


def main() -> int:
    args = set(sys.argv[1:])
    force_cpu = "--cpu" in args
    require_gpu = "--require-gpu" in args

    glslc = None if force_cpu else glslc_path()
    enable_gpu = glslc is not None

    if require_gpu and not enable_gpu:
        print(
            "::error::--require-gpu was passed but glslc is not installed. "
            "Install it (apt-get install -y glslc) before building."
        )
        return 1

    print("glslc: %s" % (glslc or "not found"))
    print("mode : %s" % ("GPU (Vulkan enabled)" if enable_gpu else "CPU only"))

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

        if cmake.is_file() and patch_cmake(cmake, enable_gpu):
            patched += 1
            print(
                "patched %s (GGML_VULKAN=%s)"
                % (cmake, "ON" if enable_gpu else "OFF")
            )

        if gradle.is_file() and patch_gradle(gradle, enable_gpu):
            patched += 1
            print(
                "patched %s (%s %s)"
                % (
                    gradle,
                    "kept" if enable_gpu else "dropped",
                    GRADLE_FLAG,
                )
            )

    if patched == 0:
        print("native_llama already in the requested state; nothing to do")
    else:
        print("patched %d file(s)" % patched)

    if enable_gpu:
        print(
            "Vulkan enabled: the APK accepts n_gpu_layers > 0 and will fall "
            "back to the CPU on devices without a working Vulkan driver."
        )
    else:
        print("Vulkan disabled: inference runs on the CPU backend.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
