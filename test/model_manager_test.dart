/// Tests for model-download integrity, resume planning and hashing.
///
/// Every check here runs offline: the download decision logic is deliberately
/// split into pure functions ([verifyDownload], [planResume],
/// [interpretRangedGet], [pinToCommit], [sha256HexOfBytes]) so the exact rules
/// the downloader follows can be pinned without a network, a device, or a real
/// 1.9 GB transfer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/model_manager.dart';
import 'package:localmind/domain/models/local_model.dart';

/// A 64-hex SHA-256, used where the actual value does not matter.
const String _shaA =
    '1111111111111111111111111111111111111111111111111111111111111111';
const String _shaB =
    '2222222222222222222222222222222222222222222222222222222222222222';
const String _commit = '9217f5db79a29953eb74d5343926648285ec7e67';

void main() {
  group('verifyDownload', () {
    test('accepts a complete file with a matching hash', () {
      final v = verifyDownload(
        receivedBytes: 1000,
        expectedSize: 1000,
        contentLength: 1000,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.ok, isTrue);
      expect(v.verdict, DownloadVerdict.ok);
    });

    test('accepts a complete file when Content-Length is absent', () {
      // Chunked responses may have no Content-Length; the manifest size and
      // hash still have to line up.
      final v = verifyDownload(
        receivedBytes: 1000,
        expectedSize: 1000,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.ok, isTrue);
    });

    test('verifies a resumed download against the full-file size', () {
      // After a 206 resume the received count is the TOTAL size of the .part
      // (existing + newly fetched). The server's Content-Length describes only
      // the remaining bytes, so it must not be passed in — the finished file
      // must match the manifest size exactly.
      final v = verifyDownload(
        receivedBytes: 5000,
        expectedSize: 5000,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.ok, isTrue);
      expect(v.verdict, DownloadVerdict.ok);
    });

    test('rejects a truncated file (fewer bytes than the manifest size)', () {
      final v = verifyDownload(
        receivedBytes: 900,
        expectedSize: 1000,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.ok, isFalse);
      expect(v.verdict, DownloadVerdict.truncated);
    });

    test(
      'rejects a short body even when it claims success (Content-Length)',
      () {
        // A chunked/early-closed body can end "cleanly" but short; comparing to
        // the server's own Content-Length catches it.
        final v = verifyDownload(
          receivedBytes: 900,
          expectedSize: 1000,
          contentLength: 1000,
          expectedSha256: _shaA,
          actualSha256: _shaA,
        );
        expect(v.verdict, DownloadVerdict.truncated);
      },
    );

    test('rejects a file larger than expected', () {
      final v = verifyDownload(
        receivedBytes: 1001,
        expectedSize: 1000,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.verdict, DownloadVerdict.oversized);
    });

    test('rejects a wrong SHA-256 even when the size is right', () {
      final v = verifyDownload(
        receivedBytes: 1000,
        expectedSize: 1000,
        expectedSha256: _shaA,
        actualSha256: _shaB,
      );
      expect(v.ok, isFalse);
      expect(v.verdict, DownloadVerdict.checksumMismatch);
    });

    test('fails closed when the manifest has no usable SHA-256', () {
      for (final bad in [null, '', 'not-a-hash', 'abc123']) {
        final v = verifyDownload(
          receivedBytes: 1000,
          expectedSize: 1000,
          expectedSha256: bad,
          actualSha256: _shaA,
        );
        expect(
          v.verdict,
          DownloadVerdict.missingChecksum,
          reason: 'expectedSha256=$bad',
        );
      }
    });

    test('fails closed when the manifest has no usable size', () {
      final v = verifyDownload(
        receivedBytes: 1000,
        expectedSize: 0,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.verdict, DownloadVerdict.badExpectedSize);
    });

    test('rejects an empty/zero-length file', () {
      final v = verifyDownload(
        receivedBytes: 0,
        expectedSize: 1000,
        expectedSha256: _shaA,
        actualSha256: _shaA,
      );
      expect(v.verdict, DownloadVerdict.empty);
    });

    test('compares hashes case-insensitively', () {
      final v = verifyDownload(
        receivedBytes: 10,
        expectedSize: 10,
        expectedSha256: _shaA.toUpperCase(),
        actualSha256: _shaA,
      );
      expect(v.ok, isTrue);
    });
  });

  group('planResume', () {
    test('computes the resume range and If-Range validator', () {
      final plan = planResume(
        existingBytes: 1000,
        expectedSize: 5000,
        acceptRangesBytes: true,
        storedEtag: 'W/"abc123"',
      );
      expect(plan.restart, isFalse);
      expect(plan.isResume, isTrue);
      expect(plan.startByte, 1000);
      expect(plan.headers['Range'], 'bytes=1000-');
      expect(plan.headers['If-Range'], 'W/"abc123"');
    });

    test('prefers a stored ETag over Last-Modified', () {
      final plan = planResume(
        existingBytes: 5,
        expectedSize: 100,
        acceptRangesBytes: true,
        storedEtag: '"etag"',
        storedLastModified: 'Tue, 01 Jan 2030 00:00:00 GMT',
      );
      expect(plan.headers['If-Range'], '"etag"');
    });

    test('falls back to Last-Modified when there is no ETag', () {
      final plan = planResume(
        existingBytes: 5,
        expectedSize: 100,
        acceptRangesBytes: true,
        storedLastModified: 'Tue, 01 Jan 2030 00:00:00 GMT',
      );
      expect(plan.headers['If-Range'], 'Tue, 01 Jan 2030 00:00:00 GMT');
    });

    test('restarts cleanly when there is no partial file', () {
      final plan = planResume(existingBytes: 0, expectedSize: 5000);
      expect(plan.restart, isTrue);
      expect(plan.startByte, 0);
      expect(plan.headers, isEmpty);
    });

    test('restarts when the server does not advertise byte ranges', () {
      final plan = planResume(
        existingBytes: 1000,
        expectedSize: 5000,
        acceptRangesBytes: false,
        storedEtag: '"etag"',
      );
      expect(plan.restart, isTrue);
      expect(plan.startByte, 0);
    });

    test('restarts when there is no stored validator to guard the range', () {
      final plan = planResume(
        existingBytes: 1000,
        expectedSize: 5000,
        acceptRangesBytes: true,
      );
      expect(plan.restart, isTrue);
    });

    test('restarts when the partial already covers the whole file', () {
      final plan = planResume(
        existingBytes: 5000,
        expectedSize: 5000,
        acceptRangesBytes: true,
        storedEtag: '"etag"',
      );
      expect(plan.restart, isTrue);
    });

    test('restarts when the stored partial was for a different size', () {
      // A new manifest pins a different size, so the old partial is not ours.
      final plan = planResume(
        existingBytes: 1000,
        expectedSize: 5000,
        acceptRangesBytes: true,
        storedEtag: '"etag"',
        storedExpectedSize: 4000,
      );
      expect(plan.restart, isTrue);
      expect(plan.startByte, 0);
    });

    test('resumes when the stored Accept-Ranges is unknown', () {
      // A 206 response often omits Accept-Ranges, so the stored value is
      // null ("unknown"). Unknown must mean "try it" — treating it as "no
      // ranges" discarded every partial and restarted 2 GB files from zero
      // after the first interruption.
      final plan = planResume(
        existingBytes: 1000,
        expectedSize: 5000,
        storedEtag: '"etag"',
      );
      expect(plan.restart, isFalse);
      expect(plan.isResume, isTrue);
      expect(plan.startByte, 1000);
      expect(plan.headers['Range'], 'bytes=1000-');
      expect(plan.headers['If-Range'], '"etag"');
    });
  });

  group('interpretRangedGet', () {
    test('resumes on a 206 whose Content-Range starts where we asked', () {
      final verdict = interpretRangedGet(
        statusCode: 206,
        requestedStart: 1000,
        contentRangeStart: 1000,
      );
      expect(verdict, RangeVerdict.resume);
    });

    test('a 200 (range ignored) triggers a restart', () {
      // The critical case: the server sent the whole file from byte 0.
      final verdict = interpretRangedGet(
        statusCode: 200,
        requestedStart: 1000,
        contentRangeStart: null,
      );
      expect(verdict, RangeVerdict.restart);
    });

    test('a 206 from an unexpected offset triggers a restart', () {
      final verdict = interpretRangedGet(
        statusCode: 206,
        requestedStart: 1000,
        contentRangeStart: 500,
      );
      expect(verdict, RangeVerdict.restart);
    });

    test('a 416 or any other status triggers a restart', () {
      expect(
        interpretRangedGet(
          statusCode: 416,
          requestedStart: 1000,
          contentRangeStart: null,
        ),
        RangeVerdict.restart,
      );
      expect(
        interpretRangedGet(
          statusCode: 500,
          requestedStart: 1000,
          contentRangeStart: null,
        ),
        RangeVerdict.restart,
      );
    });
  });

  group('resumeValidator', () {
    test('prefers a non-empty ETag', () {
      expect(resumeValidator(etag: '"e"', lastModified: 'x'), '"e"');
    });

    test('ignores a blank ETag and uses Last-Modified', () {
      expect(resumeValidator(etag: '  ', lastModified: 'lm'), 'lm');
    });

    test('returns null when nothing usable is present', () {
      expect(resumeValidator(), isNull);
      expect(resumeValidator(etag: '', lastModified: ''), isNull);
    });
  });

  group('pinToCommit', () {
    test('rewrites resolve/main onto the pinned commit', () {
      final pinned = pinToCommit(
        'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/'
        'qwen2.5-0.5b-instruct-q4_k_m.gguf',
        _commit,
      );
      expect(pinned, contains('/resolve/$_commit/'));
      expect(pinned, isNot(contains('/resolve/main/')));
    });

    test('handles a nested path under resolve/main', () {
      final pinned = pinToCommit(
        'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/'
        'resolve/main/onnx/model.onnx',
        _commit,
      );
      expect(pinned, endsWith('/resolve/$_commit/onnx/model.onnx'));
    });

    test('refuses a non-commit sha instead of falling back to main', () {
      expect(
        () => pinToCommit(
          'https://huggingface.co/a/b/resolve/main/x.gguf',
          'main',
        ),
        throwsArgumentError,
      );
      expect(
        () => pinToCommit('https://huggingface.co/a/b/resolve/main/x.gguf', ''),
        throwsArgumentError,
      );
    });

    test('refuses a URL that is not a resolvable HF URL', () {
      expect(
        () => pinToCommit('https://example.com/x/y.gguf', _commit),
        throwsArgumentError,
      );
    });
  });

  group('sha256HexOfBytes', () {
    test('matches the published vector for the empty input', () {
      expect(
        sha256HexOfBytes(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('matches the published vector for "abc"', () {
      expect(
        sha256HexOfBytes(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('file hashing in chunks matches in-memory hashing', () async {
      // The downloader hashes the finished `.part` by reading it in chunks; the
      // digest must not depend on the read block size crossing a 64-byte
      // boundary.
      final data = List<int>.generate(4096, (i) => i % 251);
      final dir = Directory.systemTemp.createTempSync('mm_hash');
      try {
        final file = File('${dir.path}/blob.bin');
        await file.writeAsBytes(data);
        expect(await sha256HexOfFile(file.path), sha256HexOfBytes(data));
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('integrity manifest', () {
    test('pins every catalog file to a commit and a hash', () {
      for (final m in ModelCatalog.all) {
        final integrity = integrityFor(m);
        expect(integrity, isNotNull, reason: '${m.id} has no manifest');
        final spec = integrity!;
        expect(
          isImmutableCommitSha(spec.commitSha),
          isTrue,
          reason: '${m.id} commit is not 40-hex',
        );
        for (final f in m.files) {
          final entry = spec.files[f.name];
          expect(
            entry,
            isNotNull,
            reason: '${m.id} is missing an entry for ${f.name}',
          );
          final e = entry!;
          expect(e.size, greaterThan(0));
          expect(e.sha256.length, 64, reason: '${f.name} hash length');
          expect(
            RegExp(r'^[0-9a-f]{64}$').hasMatch(e.sha256),
            isTrue,
            reason: '${f.name} hash is not lowercase hex',
          );
        }
      }
    });

    test('moondream2 size covers weights and projector', () {
      final integrity = integrityFor(ModelCatalog.moondream2)!;
      final total = integrity.files.values.fold<int>(0, (a, f) => a + f.size);
      // 1,059,610,016 + 909,777,984
      expect(total, 1969388000);
      expect(ModelCatalog.moondream2.approxBytes, total);
    });

    test('qwen3.5 size covers weights and projector', () {
      final integrity = integrityFor(ModelCatalog.qwen35_08b)!;
      final total = integrity.files.values.fold<int>(0, (a, f) => a + f.size);
      // 532,517,120 weights + 204,987,232 mmproj
      expect(total, 737504352);
      expect(ModelCatalog.qwen35_08b.approxBytes, total);
    });

    test('qwen3.5 is pinned to an immutable commit, not main', () {
      final integrity = integrityFor(ModelCatalog.qwen35_08b)!;
      expect(isImmutableCommitSha(integrity.commitSha), isTrue);
      expect(integrity.commitSha, '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0');
    });

    test('every manifest entry keys back to a real catalog file', () {
      // Guards against a rename leaving an orphan manifest entry behind.
      for (final m in ModelCatalog.all) {
        final names = m.files.map((f) => f.name).toSet();
        for (final key in integrityFor(m)!.files.keys) {
          expect(names, contains(key), reason: '${m.id} orphan entry $key');
        }
      }
    });
  });
}
