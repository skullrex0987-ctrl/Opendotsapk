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
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/security/crypto_box.dart';
import '../../core/utils/log.dart';

class SecureStore {
  SecureStore._();

  static SecureStore? _instance;
  static SecureStore get instance => _instance ??= SecureStore._();

  static const String _dbKeyName = 'localmind.db.key';

  /// {@macro cloud_api_key_name}
  static String apiKeyName(String providerId) => 'cloud.apikey.$providerId';

  /// Extra per-provider config (base URL, model, org) — not secret, but kept
  /// here so a provider is configured in exactly one place.
  static String providerConfigName(String providerId) =>
      'cloud.config.$providerId';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  bool _unavailable = false;

  /// True when the platform keystore could not be used. The UI shows a banner.
  bool get isUnavailable => _unavailable;

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      Log.w('SecureStore.read($key) failed: $e');
      _unavailable = true;
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      Log.w('SecureStore.write($key) failed: $e');
      _unavailable = true;
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
  /// Returns null if the keystore is unusable, in which case the caller should
  /// call [CryptoBox.disable] and continue in plaintext.
  Future<String?> databaseKey() async {
    try {
      final existing = await _read(_dbKeyName);
      if (existing != null && existing.isNotEmpty) return existing;

      final fresh = CryptoBox.generateKeyBase64();
      await _write(_dbKeyName, fresh);
      Log.i('Generated a new database encryption key');
      return fresh;
    } catch (e) {
      Log.w('Could not obtain a database key, continuing unencrypted: $e');
      return null;
    }
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
