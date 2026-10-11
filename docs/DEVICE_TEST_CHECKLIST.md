# Device test checklist

Nothing in this repository has been run on a phone since v1.2.0. The build is
green and the unit tests pass, but **a green CI run is not evidence that the app
works** — the infinite "Thinking…" bug in v1.1.0 compiled cleanly and passed 113
tests, and only appeared on real hardware. Treat every item below as unverified
until someone has done it.

Target: arm64 Android 9 (API 28) or newer.

---

## 0. Before anything else

- [ ] Install the current APK. If an older build is installed, **uninstall first**
      — signing is still debug-key, so the signature may not match and an in-place
      update will fail with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
- [ ] Launch, confirm no crash on start.
- [ ] Send "hi". **This is the v1.1.0 regression**: confirm a reply actually
      streams and completes, rather than sitting on "Thinking…" forever.

---

## 1. Model download (task B3) — the owner-reported bug

Use **Moondream2** specifically; it is the one that looped.

- [ ] Start the Moondream2 download. Note the displayed size — it should now say
      **~1.97 GB**, not 1.3 GB.
- [ ] **Interrupt it deliberately.** At ~20%, turn the screen off / background the
      app / enable airplane mode, then restore and reopen Settings → Models.
- [ ] Confirm it does **not** restart from zero. The partial file should survive
      (look for a `.part` next to the model, plus a `.part.meta`).
- [ ] Tap download again and confirm it **resumes** rather than re-downloading
      the first 20%.
- [ ] Let it finish. Confirm the file is promoted (`.part` gone) and the model
      shows as installed.
- [ ] Confirm a **second** download attempt does not happen on the next launch.
- [ ] If it completes but the app says "not installed", the SHA-256 or size in
      `modelIntegrityManifest` is wrong — capture the log line naming the
      expected vs actual hash.

**Known gaps that will still show up here:**
- There is **no foreground service**, so a download still dies if Android
  suspends the app. It now *resumes* instead of restarting, which is the fix for
  the loop, but it cannot survive backgrounding indefinitely.
- Free-space is not checked (no statfs available without a new dependency).

---

## 2. Tool permissions and the agent (task A1)

- [ ] Settings → Tools. Change a tool's permission, force-quit the app, reopen.
      The choice must **persist** (it previously reset every restart).
- [ ] Confirm `send_sms`, `add_contact`, `create_calendar_event`, `set_alarm`,
      `open_app`, `create_note`, `read_notes` are listed as **unsupported** and
      that the model never offers to use them. They must not claim success.
- [ ] Ask something requiring the location tool with permission set to **block** —
      it must refuse.
- [ ] Set it to **ask** and confirm a prompt appears. Deny it — the tool must not
      run. (The confirmation sheet may not be wired yet; if no prompt appears and
      the tool simply does not run, that is the fail-closed behaviour and is
      correct, but note it.)
- [ ] Confirm `get_location` and `analyze_image` still work.

**Not yet wired:** the agent is not reachable from chat (no Agent-mode toggle),
so most of this is only testable through the permission UI until that lands.

---

## 3. Encryption safety (task A4)

This is the data-loss fix, so test it destructively on a **throwaway profile**.

- [ ] Send a few messages so there is encrypted data.
- [ ] Force-quit, reopen. Messages must still be readable (not blank).
- [ ] **Screen lock:** set a device PIN, lock the phone, unlock, reopen the app.
      Messages must still decrypt. If they are blank, the Keystore read is
      failing and the key was not regenerated (correct) — check for the
      "Secure storage unavailable" state.
- [ ] Confirm there is **no on-screen banner** claiming encryption is unavailable
      during normal use.
- [ ] **Backup test (optional):** `adb backup` the app. Confirm the backup does
      **not** contain `databases/` (allowBackup=false + backup rules).

---

## 4. Signing and updates (task A3)

Cannot be fully tested until a real keystore exists.

- [ ] Human action: generate a keystore with `keytool` and add the four GitHub
      secrets — see `docs/RELEASE_SIGNING.md`.
- [ ] After that, confirm a release is no longer named
      `*-DEBUGSIGNED-NOT-UPDATABLE.apk`.
- [ ] Install release N, then release N+1 **over it** without uninstalling.
      This is what the whole task is for; it must succeed.

---

## 5. Barely-tested areas

- [ ] **Vision:** download Moondream2, attach a photo from the gallery, confirm a
      description comes back (or an honest error — never a fabricated one).
- [ ] **GPU:** Settings → Performance. Record the reported backend, then run the
      benchmark on both CPU and GPU and record tok/s for each. **Do not assume
      GPU is faster** — on midrange Mali it often is not. Report the numbers.
- [ ] **Cloud BYOK:** add a key, send a message, confirm it leaves the device
      only when expected. Confirm Private mode blocks it.
- [ ] **Stop button:** (not implemented yet — see A5.)

---

## Recording results

For each item, record: device model, SoC, Android version, pass/fail, and the
exact observed behaviour. Add a row to the evidence log in
`docs/AUDIT_PROGRESS.md`. If something fails, capture `adb logcat` around the
failure — several of these bugs are silent by design and only visible in logs.
