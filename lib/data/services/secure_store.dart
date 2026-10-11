/// Encrypted key/value storage built on the platform keystore.
///
/// Wraps `flutter_secure_storage` (Android Keystore) and owns two things:
///
///  * **Cloud provider API keys** — bring-your-own-key. The user pastes their
///    own OpenAI/Anthropic/... key; it is written straight to the Keystore and
///    read only when a request is about to be made. It is never written to
///    `shared_preferences`, never logged, and never included in the diagnostics
///    export.
///  * **The local database key** — a random 256-bit key used by `CryptoBox` to
///    encrypt message and memory contents at rest.
///
/// Degrades rather than blocks: if the platform keystore is unavailable (some
/// emulators, some custom ROMs) the app keeps working in plaintext and surfaces
/// a warning, instead of refusing to start.
///
/// ## Why reads are typed
///
/// A keystore read can fail in two very different ways, and the difference is
/// the whole ballgame:
///
///  * **the slot is empty** — no key has ever been written. Minting one is
///    correct and harmless;
///  * **the read threw** — Keystore unavailable, bad padding, device still
///    locked, value corrupt. The key may well still exist.
///
/// Collapsing the second into the first is data loss: the caller sees "no key
/// yet", generates a fresh one, stores it, and every row encrypted under the
/// original key now decrypts to garbage. [SecureReadResult] keeps the two
/// cases apart, and [databaseKey] never regenerates on a [SecureReadError].
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/crypto_box.dart';
import '../../core/utils/log.dart';

/// The outcome of a single keystore read.
///
/// This is deliberately not a nullable `String`: `null` cannot say *why* it is
/// null, and "absent" versus "unreadable" is exactly the distinction the
/// database key depends on.
sealed class SecureReadResult {
  const SecureReadResult();
}

/// The keystore answered and the slot is empty: the value genuinely does not
/// exist yet. This is the *only* state in which minting a new key is safe.
final class SecureNotFound extends SecureReadResult {
  const SecureNotFound();
}

/// The keystore answered and returned a value (which may be the empty string).
final class SecureValue extends SecureReadResult {
  final String value;
  const SecureValue(this.value);
}

/// The keystore threw: unavailable, bad padding, device locked, and so on. The
/// value is *unknown* — it may still exist. Callers must never treat this as
/// absence.
final class SecureReadError extends SecureReadResult {
  final Object error;
  final StackTrace? stackTrace;
  const SecureReadError(this.error, [this.stackTrace]);
}

/// Coarse health of the keystore, for the app to inspect — for example, to
/// decide whether to warn the user that at-rest encryption is not active.
///
/// This is informational only. It is **never** used to justify re-keying.
enum SecureStoreStatus {
  /// Reads and writes are succeeding.
  ok,

  /// A read or write threw. The app degrades to plaintext for this session and
  /// leaves existing ciphertext untouched instead of re-encrypting it under a
  /// fresh key.
  unavailable,

  /// A read failed and could not be recovered after retries. Encrypted data
  /// that is present may be unreadable right now, but the key was NOT
  /// regenerated and nothing was overwritten. Recovery, if any, is a
  /// user-confirmed decision — see [SecureStore.resetDatabaseKey].
  readError,
}

/// Thrown by [SecureStore.databaseKey] when the key exists (or may exist) but
/// could not be read.
///
/// It is an exception rather than a `null` return on purpose: `null` means
/// "no key yet", and a caller that confuses the two regenerates the key and
/// destroys the user's data. A throw forces the caller to decide explicitly.
class SecureStoreReadException implements Exception {
  final String key;
  final Object cause;

  SecureStoreReadException(this.key, this.cause);

  @override
  String toString() => 'SecureStoreReadException: read "$key" failed: $cause';
}

class SecureStore {
  SecureStore._();

  static SecureStore? _instance;
  static SecureStore get instance => _instance ??= SecureStore._();

  static const String _dbKeyName = 'localmind.db.key';

  /// Bounded retry policy for reads.
  ///
  /// Keystore hiccups are usually transient (the device was just unlocked, the
  /// key is not yet available). A couple of short retries clear them without
  /// making startup wait noticeably, and without ever touching the stored key.
  static const int _readAttempts = 3;
  static const Duration _readBackoffBase = Duration(milliseconds: 60);

  /// {@macro cloud_api_key_name}
  static String apiKeyName(String providerId) => 'cloud.apikey.$providerId';

  /// Extra per-provider config (base URL, model, org) — not secret, but kept
  /// here so a provider is configured in exactly one place.
  static String providerConfigName(String providerId) =>
      'cloud.config.$providerId';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  SecureStoreStatus _status = SecureStoreStatus.ok;

  /// Current keystore health, for callers that want to surface it. Setting a
  /// non-`ok` value never triggers any recovery on its own — there is no code
  /// path here that re-keys or overwrites data to "fix" a bad status.
  SecureStoreStatus get status => _status;

  /// True when the platform keystore could not be used. The UI shows a banner.
  bool get isUnavailable => _status != SecureStoreStatus.ok;

  // ------------------------------------------------------------ raw access

  /// Read [key], retrying transient keystore failures with a short backoff,
  /// and report *why* it failed instead of collapsing everything to `null`.
  ///
  /// Retries never write: they only re-attempt the read. A failed read is
  /// always reported as [SecureReadError], never as [SecureNotFound].
  Future<SecureReadResult> _readTyped(String key) async {
    Object? lastError;
    StackTrace? lastStack;

    for (var attempt = 0; attempt < _readAttempts; attempt++) {
      try {
        final value = await _storage.read(key: key);
        _status = SecureStoreStatus.ok;
        return value == null ? const SecureNotFound() : SecureValue(value);
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        if (attempt < _readAttempts - 1) {
          // Exponential-ish, but short: 60ms then 120ms.
          await Future<void>.delayed(_readBackoffBase * (1 << attempt));
        }
      }
    }

    _status = SecureStoreStatus.readError;
    Log.w('SecureStore.read($key) failed after $_readAttempts attempts: '
        '$lastError');
    return SecureReadError(lastError!, lastStack);
  }

  /// Non-critical read (API keys, provider config).
  ///
  /// These keep returning `null` on failure so a keystore wobble cannot break
  /// provider configuration. The database key does NOT go through here — it
  /// must distinguish "absent" from "unreadable".
  Future<String?> _read(String key) async {
    final result = await _readTyped(key);
    return result is SecureValue ? result.value : null;
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      _status = SecureStoreStatus.ok;
    } catch (e) {
      Log.w('SecureStore.write($key) failed: $e');
      _status = SecureStoreStatus.unavailable;
      rethrow;
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      Log.w('SecureStore.delete($key) failed: $e');
    }
  }

  // ------------------------------------------------------------ API keys

  Future<String?> apiKey(String providerId) => _read(apiKeyName(providerId));

  Future<void> setApiKey(String providerId, String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await _delete(apiKeyName(providerId));
      return;
    }
    await _write(apiKeyName(providerId), trimmed);
    Log.i('Stored API key for "$providerId" in the platform keystore');
  }

  Future<void> deleteApiKey(String providerId) =>
      _delete(apiKeyName(providerId));

  Future<bool> hasApiKey(String providerId) async {
    final v = await apiKey(providerId);
    return v != null && v.isNotEmpty;
  }

  Future<Map<String, String>> providerConfig(String providerId) async {
    final raw = await _read(providerConfigName(providerId));
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return decoded.map((k, v) => MapEntry(k, '$v'));
    } catch (_) {
      return const {};
    }
  }

  Future<void> setProviderConfig(
    String providerId,
    Map<String, String> config,
  ) async {
    if (config.isEmpty) {
      await _delete(providerConfigName(providerId));
      return;
    }
    await _write(providerConfigName(providerId), jsonEncode(config));
  }

  // --------------------------------------------------------- database key

  /// Fetch the database key, creating it on first run.
  ///
  /// A fresh key is minted **only** when the keystore says the slot is empty
  /// ([SecureNotFound]) — genuinely no key yet.
  ///
  /// If the read failed ([SecureReadError]) this throws
  /// [SecureStoreReadException] instead of regenerating. A regenerated key
  /// cannot decrypt anything written under the old one, so silently minting
  /// one would turn every message, note, memory and document chunk into an
  /// empty string: the user's data would be destroyed without a trace. On a
  /// throw the caller (`main`) runs in plaintext for this session and leaves
  /// the stored ciphertext and key exactly where they are.
  ///
  /// Returns the key string, or `null` only when the caller has explicitly
  /// opted into plaintext (it never returns `null` to mean "the read failed").
  Future<String?> databaseKey() async {
    final result = await _readTyped(_dbKeyName);

    if (result is SecureReadError) {
      Log.e('database key read failed; refusing to regenerate — a new key '
          'would orphan every previously encrypted row');
      throw SecureStoreReadException(_dbKeyName, result.error);
    }

    if (result is SecureValue && result.value.isNotEmpty) {
      return result.value;
    }

    // Reached only for SecureNotFound, or an unusable empty slot. This is the
    // one and only place a database key may be created.
    final fresh = CryptoBox.generateKeyBase64();
    await _write(_dbKeyName, fresh);
    Log.i('Generated a new database encryption key');
    return fresh;
  }

  /// **Destructive. Requires explicit, user-confirmed intent before calling.**
  ///
  /// Deletes the stored database key so the next [databaseKey] call mints a
  /// fresh one. Everything encrypted under the deleted key — chat history,
  /// memories, notes, document chunks — becomes permanently unreadable. That
  /// is why this is the *last resort* for a genuinely lost key, and never a
  /// recovery step taken automatically.
  ///
  /// The UI must show the user a confirmation (for example "Reset encrypted
  /// data? Your chat history and memories will be permanently erased") and
  /// proceed only on an explicit yes. Do not call this from any error path or
  /// catch block. After it returns, the caller is responsible for clearing the
  /// now-unreadable rows and re-initialising the store under the new key.
  Future<void> resetDatabaseKey() async {
    await _delete(_dbKeyName);
    _status = SecureStoreStatus.ok;
    Log.w('Database key reset at the user\'s request — previously encrypted '
        'rows are now unreadable');
  }

  /// Wipe every secret. Used by "Erase all data".
  Future<void> wipe() async {
    try {
      await _storage.deleteAll();
      Log.w('SecureStore wiped');
    } catch (e) {
      Log.w('SecureStore.wipe failed: $e');
    }
  }
}
