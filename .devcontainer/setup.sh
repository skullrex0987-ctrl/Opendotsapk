#!/usr/bin/env bash
# Codespaces bootstrap: Flutter SDK + Android SDK (platform 34, build-tools 34).
# Runs once when the Codespace is created. Takes ~4-6 minutes.
set -euo pipefail

FLUTTER_VERSION="3.47.7"
FLUTTER_DIR="$HOME/flutter"
ANDROID_SDK="$HOME/android-sdk"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

echo "==> [1/5] Installing Flutter $FLUTTER_VERSION"
if [ ! -d "$FLUTTER_DIR" ]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git "$FLUTTER_DIR"
else
  echo "    Flutter already present, skipping clone"
fi
export PATH="$FLUTTER_DIR/bin:$PATH"

git config --global --add safe.directory "$FLUTTER_DIR"

echo "==> [2/5] Installing Android cmdline-tools"
mkdir -p "$ANDROID_SDK/cmdline-tools"
if [ ! -d "$ANDROID_SDK/cmdline-tools/latest" ]; then
  cd /tmp
  curl -fsSL -o cmdline-tools.zip "$CMDLINE_TOOLS_URL"
  unzip -q cmdline-tools.zip -d "$ANDROID_SDK/cmdline-tools"
  mv "$ANDROID_SDK/cmdline-tools/cmdline-tools" \
     "$ANDROID_SDK/cmdline-tools/latest"
  rm -f cmdline-tools.zip
  cd -
else
  echo "    cmdline-tools already present, skipping download"
fi

export ANDROID_SDK_ROOT="$ANDROID_SDK"
export ANDROID_HOME="$ANDROID_SDK"
export PATH="$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$PATH"

echo "==> [3/5] Accepting Android licenses"
yes | sdkmanager --licenses > /dev/null 2>&1 || true

echo "==> [4/5] Installing Android SDK packages (platform-34, build-tools 34)"
sdkmanager --install \
  "platform-tools" \
  "platforms;android-34" \
  "build-tools;34.0.0" > /dev/null

echo "==> [5/5] Configuring Flutter"
flutter config --android-sdk "$ANDROID_SDK" > /dev/null
flutter config --no-analytics > /dev/null
flutter precache --android > /dev/null 2>&1 || true

flutter doctor -v || true

echo ""
echo "================================================"
echo " Codespace ready."
echo " Build the APK with:"
echo ""
echo "     flutter build apk --release"
echo ""
echo " Output:"
echo "     build/app/outputs/flutter-apk/app-release.apk"
echo "================================================"
