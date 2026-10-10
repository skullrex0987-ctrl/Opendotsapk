/// Tests for at-rest encryption and the float32 vector codec.
///
/// The codec test is not busywork: an endianness mistake here would not throw,
/// it would silently return garbage vectors and make every memory search wrong.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/core/security/crypto_box.dart';
import 'package:localmind/data/database/database_helper.dart';

void main() {
  group('CryptoBox', () {
    late CryptoBox box;

    setUp(() {
      box = CryptoBox.instance;
      box.installKey(CryptoBox.generateKeyBase64());
    });

    test('round-trips a simple string', () async {
      const plain = 'hello localmind';
      final enc = await box.encrypt(plain);
      expect(enc, isNot(plain));
      expect(await box.decrypt(enc), plain);
    });

    test('ciphertext carries the versioned prefix', () async {
      final enc = await box.encrypt('x');
      expect(enc.startsWith('enc:v1:'), isTrue);
    });

    test('is non-deterministic: same input never yields same ciphertext', () async {
      final a = await box.encrypt('repeat');
      final b = await box.encrypt('repeat');
      expect(a, isNot(b));
      expect(await box.decrypt(a), 'repeat');
      expect(await box.decrypt(b), 'repeat');
    });

    test('round-trips unicode and emoji', () async {
      const plain = 'héllo 世界 🍠 مرحبا';
      expect(await box.decrypt(await box.encrypt(plain)), plain);
    });

    test('round-trips a long string', () async {
      final plain = 'lorem ipsum ' * 2000;
      expect(await box.decrypt(await box.encrypt(plain)), plain);
    });

    test('empty string passes through untouched', () async {
      expect(await box.encrypt(''), '');
      expect(await box.decrypt(''), '');
    });

    test('plaintext input to decrypt is returned as-is', () async {
      expect(await box.decrypt('not encrypted'), 'not encrypted');
    });

    test('generates 32-byte keys', () {
      final k = CryptoBox.generateKeyBase64();
      expect(k.length, greaterThan(40));
      // Two calls must differ.
      expect(CryptoBox.generateKeyBase64(), isNot(k));
    });

    test('rejects a key of the wrong length instead of silently accepting it', () {
      // A truncated key would encrypt fine and then fail to decrypt later.
      expect(() => box.installKey('c2hvcnQ='), throwsArgumentError);
    });

    test('a value encrypted under a different key does not decrypt to plaintext', () async {
      final enc = await box.encrypt('secret value');

      // Swap in an unrelated key, as if the keystore entry were lost.
      final other = CryptoBox.instance;
      other.installKey(CryptoBox.generateKeyBase64());

      final out = await other.decrypt(enc);
      expect(out, isNot('secret value'));
    });

    test('detects its own output', () {
      expect(CryptoBox.isEncrypted('enc:v1:abc'), isTrue);
      expect(CryptoBox.isEncrypted('plaintext'), isFalse);
    });

    test('decrypting corrupt ciphertext returns empty rather than throwing', () async {
      // A thrown exception here would take down a list rendering hundreds of rows.
      final out = await box.decrypt('enc:v1:bm90LXJlYWxseS1jaXBoZXJ0ZXh0');
      expect(out, '');
    });

    test('decrypting truncated ciphertext returns empty', () async {
      final out = await box.decrypt('enc:v1:AAAA');
      expect(out, '');
    });
  });

  group('vector codec', () {
    test('round-trips a 384-dim vector within float32 precision', () {
      final original = List<double>.generate(
        384,
        (i) => (i % 17) / 17.0 - 0.5,
      );
      final decoded = DatabaseHelper.decodeVector(
        DatabaseHelper.encodeVector(original),
      );

      expect(decoded.length, 384);
      for (var i = 0; i < 384; i++) {
        expect(decoded[i], closeTo(original[i], 1e-6));
      }
    });

    test('encodes to exactly 4 bytes per element', () {
      final bytes = DatabaseHelper.encodeVector(List.filled(384, 0.5));
      expect(bytes.lengthInBytes, 384 * 4);
    });

    test('preserves sign', () {
      final v = <double>[-1.0, -0.5, 0.0, 0.5, 1.0];
      final d = DatabaseHelper.decodeVector(DatabaseHelper.encodeVector(v));
      expect(d, equals(v.map((e) => closeTo(e, 1e-6)).toList()));
    });

    test('rejects a byte length that is not a multiple of four', () {
      expect(
        DatabaseHelper.decodeVector(Uint8List.fromList([1, 2, 3])),
        isEmpty,
      );
    });

    test('empty vector round-trips', () {
      expect(DatabaseHelper.decodeVector(DatabaseHelper.encodeVector([])),
          isEmpty);
    });

    test('handles a sublist view (non-zero offset) correctly', () {
      // ByteData.view over a sublist is the classic way to get this wrong.
      final full = DatabaseHelper.encodeVector([1.0, 2.0, 3.0, 4.0]);
      final middle = Uint8List.sublistView(full, 4, 12);
      expect(DatabaseHelper.decodeVector(middle),
          equals([closeTo(2.0, 1e-6), closeTo(3.0, 1e-6)]));
    });
  });
}
