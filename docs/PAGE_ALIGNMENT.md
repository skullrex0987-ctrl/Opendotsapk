# 16 KB page alignment of native libraries

Android has always mapped memory in pages, and for most of Android's life the
page size on 64-bit ARM devices was 4 KB (`0x1000`). Android 15 makes 16 KB
(`0x4000`) pages a supported configuration, and any app with native code must
work with both. This document records what that means for LocalMind, what CI
now enforces, the current status of every native library the APK ships, and
what remains for a human to do.

## What 16 KB alignment is, and why Android 15 cares

A shared library (`.so`) is an ELF file whose contents are described by *program
headers*. Each `PT_LOAD` segment has a `p_align` field: the alignment the
dynamic linker must satisfy when it `mmap`s that segment. The loader maps each
segment at an address that is a multiple of `p_align`, and on a 16 KB-page
kernel it maps at 16 KB granularity. If a library was linked with a 4 KB
`p_align`, the loader cannot place its segments on the 16 KB boundaries the
kernel requires, and the library fails to load — the app either refuses to
install or crashes the first time it touches that library.

This is invisible on a 4 KB device, which is why it survives normal testing.
The fix at build time is a linker flag:

```
-Wl,-z,max-page-size=16384
```

and both modern toolchains set it for you: Android NDK r28 and higher compile
16 KB-aligned by default, and Android Gradle Plugin 8.5.1+ aligns uncompressed
shared libraries during packaging. The catch is *prebuilt* libraries: a `.so`
that a dependency ships precompiled was linked with whatever flags its
publisher used, and the app cannot change that from its own build.

Google Play requires 16 KB support for apps that target Android 15 (API 35) or
higher. Google's May 2025 announcement set November 1, 2025 for new apps and
updates; the current Android compatibility documentation gives February 1, 2027
as the date after which non-compliant *updates* are blocked. Either way, a
non-compliant app cannot ship to a 16 KB device, and LocalMind's `targetSdk` is
35, so the app is in scope.

Sources:
- https://developer.android.com/guide/practices/page-sizes
- https://android-developers.googleblog.com/2025/05/prepare-play-apps-for-devices-with-16kb-page-size.html

## What the check does

`scripts/check_page_alignment.py` opens the built APK as a ZIP, reads every
`lib/<abi>/*.so` straight out of the archive, parses each one's ELF program
headers with `pyelftools`, and asserts that every `PT_LOAD` segment has a
`p_align` that is a non-zero multiple of `0x4000` (16 KB). It prints, per
library, the alignment it found per segment, then a summary, and exits non-zero
listing the offenders (as a GitHub Actions `::error::` annotation). It needs no
device and no Android toolchain — only `pyelftools`.

CI runs it in the `build-apk.yml` workflow as the step **"Check 16 KB page
alignment of native libraries"**, immediately after the APK is collected. The
step creates its own virtualenv for `pyelftools` so a PEP 668 "externally
managed" system Python on the runner cannot block the install. The build now
fails if any shipped native library is misaligned.

## Current status of each native library

| Library | Built by | `p_align` | Status |
|---|---|---|---|
| `libonnxruntime.so` | `onnxruntime` pub package 1.4.1 → bundles ORT **1.15.1** (built 2023-12-19) | `0x1000` (4 KB) | **MISALIGNED** — all 3 `PT_LOAD` segments |
| `libllama.so`, `libnative_llama.so`, `libggml*.so` | compiled in CI from `native_llama` 1.0.1 with NDK 28.2.13676358 | expected `0x4000` | aligned (NDK r28 default; a prior audit found them aligned) — now verified every build |

The ONNX entry is measured directly: the `.so` extracted from the published
`onnxruntime` 1.4.1 archive has `p_align = 0x1000` on every `PT_LOAD` segment.
The llama/ggml entries are **not** independently re-measured here (those
libraries are only compiled inside CI, and this VPS has no Flutter/NDK); they
are listed as aligned on the strength of NDK r28's documented default and the
prior audit, and the new gate re-confirms that on every build rather than
trusting it.

## Which ONNX Runtime versions are aligned (measured)

The `onnxruntime` pub package vendors its own prebuilt `libonnxruntime.so`; the
version below is verified by downloading the corresponding Android AAR from
Maven Central and reading the `p_align` of `lib/arm64-v8a/libonnxruntime.so`.

| ORT version | `p_align` of `libonnxruntime.so` | 16 KB |
|---|---|---|
| 1.15.1 (what this app ships) | `0x1000` | no |
| 1.16.3 | `0x1000` | no |
| 1.17.3 | `0x1000` | no |
| 1.18.0 | `0x1000` | no |
| 1.19.2 | `0x1000` | no |
| 1.20.0 | `0x4000` | **yes** |

So the fix is real but newer than the packages: ONNX Runtime aligned its main
`libonnxruntime.so` for Android **starting in 1.20.0** (upstream PR
[#22076](https://github.com/microsoft/onnxruntime/pull/22076), "Enable Android
16 KB page size support", adds `-Wl,-z,max-page-size=16384` to the Android
linker flags). Note the task brief guessed "1.19+ / 1.20"; the boundary is
**1.20.0** — 1.19.2 is still misaligned. (ORT's separate Java-JNI
`libonnxruntime4j_jni.so` was fixed later, in 1.22.0; it is irrelevant here
because this app uses the package's Dart FFI bindings, not the Java API.)

## Was a fix applied? No.

`pubspec.yaml` was **not** changed, and the misalignment is **not** fixed here.
The precise reason:

1. **There is no newer `onnxruntime` pub package to bump to.** `pub.dev` lists
   six versions; the newest is **1.4.1**, published 2024-03-27 — exactly what
   the repo already pins (`onnxruntime: ^1.4.1`). The caret range therefore
   already resolves to the latest release; there is no higher version. The pub
   package is frozen at an ORT 1.15.1 payload.
2. The repository's recurring `win32` transitive-conflict hazard does **not**
   apply to this package: `onnxruntime` 1.4.1's only declared dependencies are
   `flutter` and `ffi` (`^2.0.1`). It cannot pull `win32` in at all. This point
   is moot, though, because of (1) — there is nothing to resolve.
3. The only in-repo lever that would help is a Gradle-level override in
   `android/app/build.gradle` (add `com.microsoft.onnxruntime:onnxruntime-android:1.20.0`
   and `packagingOptions.pickFirst` to displace the plugin's `.so`). That is a
   swap of the native runtime to a build the package's FFI bindings were not
   generated against, and it cannot be validated on this host (no Flutter, no
   NDK, no device). Shipping an unverifiable native-runtime swap for the
   embeddings path is worse than a visible, documented failure, so it was not
   applied.

Net: **onnxruntime is still misaligned and we cannot fix it without replacing
the package.** CI now makes that failure explicit instead of silent.

## What a human must do

Pick one, in rough order of preference:

1. **Replace or fork the `onnxruntime` plugin.** Vendor the package (or a fork)
   whose Android `jniLibs/arm64-v8a/libonnxruntime.so` comes from ONNX Runtime
   **1.20.0 or newer**, then re-verify its FFI bindings against the new C API.
   This is the clean fix and the one to prefer. After the swap the CI gate
   should pass unchanged.
2. **Override the `.so` at the Gradle layer**, only if (1) is impractical: add
   the `onnxruntime-android` Maven dependency at 1.20.0+ in
   `android/app/build.gradle` and use `packagingOptions`/`pickFirst` to ship
   that `libonnxruntime.so` instead of the plugin's. This **must** be validated
   on a 16 KB emulator or device (embeddings must still produce vectors) before
   it is trusted.
3. **Swap the embeddings runtime** entirely (e.g. an ONNX Runtime alternative
   that is already 16 KB aligned), if the above are not viable.

Do not "fix" this by editing the `.so` or the version-bump alone: the pub
package ships the binary, so nothing in `pubspec.yaml` can move it.
