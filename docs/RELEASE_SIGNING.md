# Release signing

Status: release builds are signed with a project keystore, not the debug key.

## Why this exists

Release APKs used to be signed with the auto-generated **debug** key
(`signingConfig = signingConfigs.debug` in `android/app/build.gradle`). That key
is created fresh on every machine and every CI runner, so two builds of the same
version carried **different signatures**. Android will not install an update
whose signature differs from the installed app's, so every release forced users
to uninstall first — which wipes their data — before they could update. A stable
release key fixes that: the signature is the same across builds, so updates
install in place.

A release key also cannot be swapped later without that same one-time uninstall.
**Back it up.**

## One-time: create the keystore

Run this once, on your own machine (not in CI). It creates a single keystore
file holding one signing key:

```bash
keytool -genkeypair -v \
  -keystore localmind-release.jks \
  -storetype JKS \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -alias localmind \
  -storepass 'CHANGE_ME_STORE_PASSWORD' \
  -keypass 'CHANGE_ME_KEY_PASSWORD' \
  -dname "CN=LocalMind, OU=Android, O=LocalMind, L=Unknown, ST=Unknown, C=IN"
```

Field notes, so nobody has to look them up:

- `-keystore` — the output file. Name and location are yours; the examples below
  assume `localmind-release.jks`.
- `-storetype JKS` — the format Flutter's documentation uses. `PKCS12` (keytool's
  own default since JDK 9) works too; `apksigner` accepts either.
- `-keyalg RSA -keysize 4096` and `-validity 10000` (~27 years) — Google Play
  requires a validity that outlasts the app's expected lifetime; 10000 days
  clears that comfortably.
- `-alias localmind` — the key's name inside the keystore. It must match the
  `ANDROID_KEY_ALIAS` secret below.
- `-storepass` / `-keypass` — two passwords. `keypass` may equal `storepass`;
  keep them separate if you prefer, just record both.
- `-dname` — the certificate subject. Any values are accepted.

Keep the `.jks` file and both passwords somewhere safe and **outside the
repository**. If you lose the keystore you can never ship an update to an app
already signed with it (a Play release or a direct install), and the only
remedy is a new application id. The repo already git-ignores `*.jks`,
`*.keystore` and `key.properties`, so a stray copy cannot be committed by
accident.

## Add the four GitHub secrets

Repository → **Settings → Secrets and variables → Actions → New repository
secret**. Add all four:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_B64` | the base64 of `localmind-release.jks` (see below) |
| `ANDROID_KEYSTORE_PASSWORD` | the `-storepass` value |
| `ANDROID_KEY_ALIAS` | the `-alias` value (`localmind`) |
| `ANDROID_KEY_PASSWORD` | the `-keypass` value |

### Base64-encoding the keystore

GitHub secrets are text, so the binary keystore is encoded to base64 first. The
flags differ by platform:

```bash
# Linux (GNU coreutils). -w0 disables line wrapping, which matters here: the
# whole keystore must end up on one line.
base64 -w0 localmind-release.jks > keystore.b64

# macOS (BSD base64). It uses -i / -o, not -w.
base64 -i localmind-release.jks -o keystore.b64
```

On macOS, if you write `base64 localmind-release.jks` by hand instead, check the
result is a single line — some builds insert newlines. Paste the entire contents
of `keystore.b64` (one long line) into `ANDROID_KEYSTORE_B64`.

## What CI does with them

In `.github/workflows/build-apk.yml`:

1. `ANDROID_KEYSTORE_B64` is decoded into a temp file and `android/key.properties`
   is written pointing at it. `android/app/build.gradle` reads that file (or the
   same values straight from the environment, which is what a local build uses).
2. The version name is taken from the pushed tag (`v1.2.0` → `1.2.0`) and the
   version code from the CI run number, then passed as `--build-name` /
   `--build-number`.
3. The job **fails** if `aapt2 dump badging` reports a `versionName` that does not
   equal the tag.
4. `apksigner verify --print-certs` runs and its output is attached to the
   artifact; a `SHA256SUMS` file is published next to the APK.

When the secret is not set (a fork, or a repo that has not configured signing),
the build still succeeds but uses the debug key, prints a loud warning, and the
artifact is renamed `localmind-<version>-DEBUGSIGNED-NOT-UPDATABLE.apk`. Such a
build cannot be installed as an update — the name says so on purpose.

## One-time uninstall for existing users

Switching from the debug key to the release key **changes the app signature**.
Android treats a differently-signed APK as a different app and refuses to install
it over the existing one:

- Users on a debug-signed build (every release up to now) must **uninstall once**
  before installing the first release-key build. That deletes app data unless it
  was exported first. Say so in the release notes.
- If the app was ever published to Google Play under another key, Play checks
  *that* key, and switching requires Play App Signing's key-reset flow instead.
  That is a Play-side operation, not a CI change.

After that single uninstall, every subsequent release installs in place.

## Building locally with the release key

Without CI, either export the four variables:

```bash
export ANDROID_KEYSTORE_PATH="$PWD/localmind-release.jks"
export ANDROID_KEYSTORE_PASSWORD='...'
export ANDROID_KEY_ALIAS='localmind'
export ANDROID_KEY_PASSWORD='...'
flutter build apk --release --build-name 1.2.0 --build-number 7
```

or write `android/key.properties` (path may be absolute or relative to
`android/app`):

```properties
storeFile=/absolute/path/to/localmind-release.jks
storePassword=...
keyAlias=localmind
keyPassword=...
```

`key.properties` and the keystore are git-ignored; never commit either.

## Verifying a signed APK

```bash
AAPT2=$(ls "$ANDROID_HOME"/build-tools/*/aapt2 | sort -V | tail -1)
"$AAPT2" dump badging localmind-1.2.0.apk | sed -n 's/^package: //p'

APKSIGNER=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1)/apksigner
"$APKSIGNER" verify --print-certs localmind-1.2.0.apk

sha256sum -c SHA256SUMS
```

A debug-signed artifact names its certificate "Android Debug"; a release build
names the certificate printed from your `-dname`.
