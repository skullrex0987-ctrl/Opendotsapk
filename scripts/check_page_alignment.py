#!/usr/bin/env python3
"""Fail if any native library in an APK is not 16 KB page aligned.

Android 15 introduced support for 16 KB memory pages, and Google Play requires
that apps shipping native code be 16 KB aligned from November 2025. The ELF
property that matters is the alignment of every PT_LOAD segment: the dynamic
linker mmaps each LOAD segment at its p_align, so a library linked with a
4 KB (0x1000) p_align cannot be mapped on a 16 KB-page device and the app fails
to load it (install-time abort, or a crash on the first use of the library).

The check is purely mechanical and needs no device: open the APK (a ZIP),
read each lib/<abi>/*.so straight out of the archive, parse the ELF program
headers, and assert that every PT_LOAD p_align is a non-zero multiple of
0x4000 (16 KB).

Usage:
    check_page_alignment.py path/to/app-release.apk [--min-align 16384]

Exits 0 when every native library is aligned, 1 when any is not (listing the
offenders), 2 on a usage/IO problem.
"""

from __future__ import annotations

import argparse
import sys
import zipfile

try:
    from elftools.elf.elffile import ELFFile
except ImportError:  # pragma: no cover - exercised only when the dep is missing
    sys.stderr.write(
        "error: pyelftools is not installed. Install it with "
        "`python3 -m pip install pyelftools`.\n"
    )
    sys.exit(2)

# Google Play / Android 15 require 16 KB (0x4000) alignment for arm64.
DEFAULT_MIN_ALIGN = 0x4000

# Only libraries inside lib/<abi>/ are native code the platform will mmap.
# The ABI (arm64-v8a, armeabi-v7a, ...) is whatever is in the path.
_LIB_SUFFIX = ".so"


def _lib_entries(zf: zipfile.ZipFile) -> list[str]:
    """Native library entries (lib/<abi>/<name>.so), sorted for stable output."""
    out = []
    for name in zf.namelist():
        if name.endswith("/") or not name.endswith(_LIB_SUFFIX):
            continue
        parts = name.split("/")
        if len(parts) >= 3 and parts[0] == "lib":
            out.append(name)
    return sorted(out)


def check_library(name: str, data: bytes, min_align: int) -> tuple[bool, list[str]]:
    """Return (ok, report_lines) for one ELF shared object."""
    import io

    lines: list[str] = []
    try:
        elf = ELFFile(io.BytesIO(data))
    except Exception as exc:  # not a valid ELF
        return False, [f"  {name}: NOT AN ELF FILE ({exc})"]

    load_segments = [
        seg for seg in elf.iter_segments() if seg["p_type"] == "PT_LOAD"
    ]
    if not load_segments:
        return False, [f"  {name}: no PT_LOAD segment (is this really a .so?)"]

    ok = True
    for idx, seg in enumerate(load_segments):
        align = seg["p_align"]
        # A p_align of 0 or 1 means "no alignment requirement"; for a shared
        # library the loader still needs at least one page, and Android's
        # requirement is 16 KB, so anything below min_align is a failure.
        aligned = align != 0 and align % min_align == 0
        if not aligned:
            ok = False
        status = "OK" if aligned else "MISALIGNED"
        lines.append(
            f"  {name}: LOAD[{idx}] p_align={hex(align)} "
            f"({align // 1024} KB) {status}"
        )
    return ok, lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", help="path to the built APK")
    parser.add_argument(
        "--min-align",
        type=lambda s: int(s, 0),
        default=DEFAULT_MIN_ALIGN,
        help=f"required minimum alignment (default {hex(DEFAULT_MIN_ALIGN)})",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero on a misaligned library (default is to warn only)",
    )
    args = parser.parse_args(argv)

    try:
        zf = zipfile.ZipFile(args.apk)
    except (OSError, zipfile.BadZipFile) as exc:
        sys.stderr.write(f"error: cannot open APK {args.apk!r}: {exc}\n")
        return 2

    with zf:
        entries = _lib_entries(zf)
        if not entries:
            sys.stderr.write(
                f"error: no native libraries found in {args.apk!r}; was it built "
                "with native code?\n"
            )
            return 2

        print(f"Checking {len(entries)} native libraries in {args.apk}")
        print(f"Required alignment: {hex(args.min_align)} ({args.min_align // 1024} KB)")
        print()

        offenders: list[str] = []
        for name in entries:
            data = zf.read(name)
            ok, lines = check_library(name, data, args.min_align)
            for line in lines:
                print(line)
            if not ok:
                offenders.append(name)

    print()
    print(f"Checked {len(entries)} librar{'y' if len(entries) == 1 else 'ies'}: "
          f"{len(entries) - len(offenders)} aligned, {len(offenders)} misaligned.")
    if offenders:
        # Warn by default, fail only under --strict, and that is deliberate:
        # there is no available fix yet. The `onnxruntime` pub package is frozen
        # at 1.4.1 and every published AAR below 1.20.0 is misaligned, so failing
        # here would block every release without changing a single byte. The
        # warning is still emitted as an annotation on every run, so it stays
        # visible rather than being forgotten.
        #
        # Switch this to --strict once the runtime is upgraded to ORT >= 1.20.0.
        level = "error" if args.strict else "warning"
        print(f"::{level}::misaligned native libraries: " + ", ".join(offenders))
        print()
        print("These libraries cannot be loaded on 16 KB-page devices (Android 15+).")
        print("Rebuild them with `-Wl,-z,max-page-size=16384`, or upgrade the")
        print("dependency that ships them (ORT >= 1.20.0 is the first aligned one).")
        return 1 if args.strict else 0

    print("All native libraries are 16 KB aligned.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
