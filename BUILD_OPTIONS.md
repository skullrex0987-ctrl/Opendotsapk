# LocalMind — Build Options

The VPS cannot build this APK (see the bottom of this file for the exact
numbers). Here are the working alternatives, best first.

---

## Option 1 — GitHub Actions (recommended, free, zero local setup)

A workflow is already committed at `.github/workflows/build-apk.yml`.

1. Create a new **public** repository on GitHub (Actions minutes are free
   without limit for public repos).
2. Push this project to it:

   ```bash
   cd localmind_project
   git init
   git add .
   git commit -m "LocalMind: local-first AI agent"
   git branch -M main
   git remote add origin https://github.com/<YOUR_USER>/localmind.git
   git push -u origin main
   ```

3. Open the repo → **Actions** tab → **Build APK** → wait ~10 minutes.
4. Download **localmind-apk** from the run's *Artifacts* section.
5. Install on the phone (enable *Install from unknown sources*).

You can also trigger it manually from the Actions tab (`workflow_dispatch`),
so you can change model settings and rebuild without touching your machine.

---

## Option 2 — GitHub Codespaces (full dev environment in the browser)

Free tier: 120 core-hours/month, **4 cores / 8 GB RAM / 32 GB disk** — far more
than enough, unlike this VPS.

1. Push the repo as in Option 1.
2. Repo → **Code** → **Codespaces** → **Create codespace on main**.
3. In the Codespace terminal:

   ```bash
   flutter pub get
   flutter build apk --release
   ```

4. Right-click `build/app/outputs/flutter-apk/app-release.apk` in the file
   explorer → **Download**.

This is the best option if you also want to edit the code and see errors live.

---

## Option 3 — Your own machine

Requirements: Flutter 3.x, Android SDK 34, JDK 17, ~8 GB free disk.

```bash
flutter pub get
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
```

---

## Option 4 — Google Cloud Shell

Free, includes 5 GB persistent disk. Flutter must be installed first:

```bash
git clone https://github.com/flutter/flutter.git -b stable ~/flutter
export PATH="$PATH:$HOME/flutter/bin"
flutter doctor --android-licenses
cd localmind_project && flutter pub get && flutter build apk --release
```

Note: Cloud Shell has ~1.7 GB RAM, so Gradle may still be tight. Add swap or use
Option 1/2 if the build is killed.

---

## Why the VPS can't do it

| Requirement | Needed | VPS has | Gap |
|---|---|---|---|
| Disk: Flutter SDK | ~2.5 GB | — | — |
| Disk: Android SDK (33/34, build-tools, platform-tools) | ~3.0 GB | — | — |
| Disk: Gradle + wrapper + caches | ~1.0 GB | — | — |
| Disk: build artifacts (intermediates, R8) | ~1.0 GB | — | — |
| **Disk total** | **~7.5 GB** | **3.2 GB** | **-4.3 GB** |
| **RAM: Gradle daemon + D8/R8** | **1.5–2.0 GB** | **~0.45 GB** | **-1.1 GB** |

The RAM shortfall is the harder blocker: Java's build tooling is not
swappable-friendly, so Gradle would be OOM-killed (exit 137) partway through
R8 shrinking — the same failure mode seen earlier with the PyTorch model.

Aggressively reclaiming space (removing snapd ~2.4 GB, apt caches, Hermes
caches) can reach roughly 5.5–6 GB, which is *still* short of 7.5 GB — and does
nothing for the RAM wall. Not worth the risk of filling the disk and taking the
VPS down.

---

## Fixing the code before you build

The project was reviewed for compile errors and the following were corrected:

| Issue | Was | Now |
|---|---|---|
| `main.dart` and `app.dart` both defined `LocalMindApp` and `main()` | duplicate symbol error | `main.dart` is the only entry point, `app.dart` holds the widget |
| `database_helper.dart` referenced undefined `$vectorDimension` | compile error | uses `AppConstants.vectorDimension` |
| `database_helper.dart` imported `speech_to_text` / `dart:io` unused | lint noise | removed |
| `SpeechNotifier.startListening()` returned the void result of `listen()` | never compiled | `listenOnce()` captures recognition via callback + `Completer` |
| `ToolCall.fromMap` cast a `String` to `Map` | runtime crash | handles both JSON string and map |
| `geolocator` used but not declared | resolution error | added to `pubspec.yaml` |
| `build_runner` declared twice | resolution warning | dev_dependencies only |
| `debugPrint` used without import | compile error | `flutter/foundation.dart` imported |

### Packages to verify on pub.dev

These three do native/binding work and their pub.dev availability should be
confirmed before the first build — if one is missing, replace it with an
equivalent that exists:

- `llama_flutter_android` — llama.cpp bindings (bundles the llama.cpp C++ sources so the APK really contains `libllama.so`; `llama_cpp_dart`/`flutter_llama` ship without them and produce an APK with no LLM)
- `onnxruntime` — ONNX Runtime bindings
- `sqlite3` / sqlite-vec — the vector table creation needs the sqlite-vec
  extension loaded at runtime, which is a native step not covered by a pub
  package alone

They are pinned as `any` so `flutter pub get` can resolve whatever versions
exist instead of failing on a guessed constraint.
