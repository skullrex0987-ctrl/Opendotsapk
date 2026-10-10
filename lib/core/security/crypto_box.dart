/// Application-layer encryption for data at rest.
///
/// Threat model: a stolen/unrooted phone whose backup or app sandbox is
/// extracted, or another app reading the world-readable parts of storage. The
/// key lives in the Android Keystore via `flutter_secure_storage`, so it is not
/// present in the app sandbox at all.
///
/// What this deliberately does NOT do: hide data from a rooted device or from
/// the user. The LLM runs in-process and needs plaintext to answer, so anyone
/// who can read process memory can read it. Full-database SQLCipher was
/// considered and skipped — `sqlcipher_flutter_libs` is end-of-life (its own
/// pub page says "not used anymore"), and `sqflite_sqlcipher` would pull a
/// second SQLite into an APK that already ships three native runtimes, for a
/// threat model this does not actually cover.
///
/// Wire format of an encrypted value:
///
///     enc:v1:<base64(nonce[12] || ciphertext || mac[16])>
///
/// Values without the `enc:v1:` prefix are treated as plaintext. That keeps
/// pre-existing rows readable and makes encryption opt-in per record, so a
/// partial migration can never make the database unreadable.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../utils/log.dart';

class CryptoBox {
  CryptoBox._();

  static CryptoBox? _instance;
  static CryptoBox get instance => _instance ??= CryptoBox._();

  static const String _prefix = 'enc:v1:';

  final AesGcm _algorithm = AesGcm.with256bits();

  SecretKey? _key;
  bool _disabled = false;

  /// True once a key is loaded and encryption is actually in use.
  bool get isActive => _key != null && !_disabled;

  /// Install the master key. [rawBase64] is a 32-byte key, base64-encoded,
  /// as produced by [generateKeyBase64].
  ///
  /// Throws if the key is not exactly 32 bytes — a truncated key would silently
  /// "work" and then make every previously-written row undecryptable.
  void installKey(String rawBase64) {
    final bytes = base64Decode(rawBase64);
    if (bytes.length != 32) {
      throw ArgumentError(
        'CryptoBox key must be 32 bytes, got ${bytes.length}',
      );
    }
    _key = SecretKey(bytes);
    _disabled = false;
  }

  /// Turn encryption off. Used when the platform keystore is unavailable so the
  /// app degrades to plaintext instead of refusing to start.
  void disable() {
    _key = null;
    _disabled = true;
  }

  /// Fresh 256-bit key, base64-encoded, for storage in the secure store.
  static String generateKeyBase64() {
    final rnd = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return base64Encode(bytes);
  }

  /// Encrypt [plaintext]. Returns the input unchanged when no key is loaded,
  /// so callers never have to branch.
  Future<String> encrypt(String plaintext) async {
    final key = _key;
    if (key == null || _disabled) return plaintext;
    if (plaintext.isEmpty) return plaintext;

    try {
      final box = await _algorithm.encrypt(
        utf8.encode(plaintext),
        secretKey: key,
      );
      final combined = Uint8List.fromList([
        ...box.nonce,
        ...box.cipherText,
        ...box.mac.bytes,
      ]);
      return '$_prefix${base64Encode(combined)}';
    } catch (e) {
      // Never lose the user's data because encryption failed.
      Log.w('CryptoBox.encrypt failed, storing plaintext: $e');
      return plaintext;
    }
  }

  /// Decrypt a value produced by [encrypt]. Plaintext input passes through.
  ///
  /// Returns an empty string and logs on failure — a corrupt row must not crash
  /// a list view that is rendering hundreds of them.
  Future<String> decrypt(String value) async {
    final key = _key;
    if (!value.startsWith(_prefix)) return value;
    if (key == null || _disabled) {
      Log.w('CryptoBox.decrypt: encrypted value found but no key loaded');
      return '';
    }

    try {
      final raw = base64Decode(value.substring(_prefix.length));
      if (raw.length < 12 + 16) {
        Log.w('CryptoBox.decrypt: ciphertext too short');
        return '';
      }
      final nonce = raw.sublist(0, 12);
      final mac = Mac(raw.sublist(raw.length - 16));
      final cipherText = raw.sublist(12, raw.length - 16);

      final clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
      );
      return utf8.decode(clear);
    } catch (e) {
      Log.w('CryptoBox.decrypt failed: $e');
      return '';
    }
  }

  /// True when [value] looks like it was encrypted by this class.
  static bool isEncrypted(String value) => value.startsWith(_prefix);
}
