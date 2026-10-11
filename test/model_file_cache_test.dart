/// Tests for the model-file presence cache.
///
/// The cache sits between a scrolling list of models and the filesystem, so its
/// failure mode is not "throws" — it is "lies", and it lies in two directions:
/// reporting a model as installed after the user deleted it (and wasting a
/// download), or reporting it as absent after it just finished downloading
/// (and hiding a working model). Both are asserted here.
///
/// Everything runs offline against the real filesystem in a temp directory,
/// plus an injected clock and probe for the cases that need determinism. No
/// plugin, no platform channel, no network.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/model_file_cache.dart';

void main() {
  group('FilePresence', () {
    test('missing is the zero-length, non-existent answer', () {
      expect(FilePresence.missing.exists, isFalse);
      expect(FilePresence.missing.length, 0);
    });

    test('compares by value so cached results can be asserted on', () {
      expect(
        const FilePresence(exists: true, length: 42),
        const FilePresence(exists: true, length: 42),
      );
      expect(
        const FilePresence(exists: true, length: 42),
        isNot(const FilePresence(exists: true, length: 43)),
      );
      expect(
        const FilePresence(exists: true, length: 42),
        isNot(const FilePresence(exists: false, length: 42)),
      );
    });
  });

  group('probeFilePresence', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('presence'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reports a real file with its size', () async {
      final file = File('${dir.path}/model.gguf')
        ..writeAsBytesSync(List<int>.filled(1024, 7));

      final result = await probeFilePresence(file.path);
      expect(result.exists, isTrue);
      expect(result.length, 1024);
    });

    test('reports an empty file as existing with length zero', () async {
      final file = File('${dir.path}/empty.txt')..writeAsBytesSync(const []);

      final result = await probeFilePresence(file.path);
      expect(result.exists, isTrue);
      expect(result.length, 0);
    });

    test('reports a missing path as missing, not as length -1', () async {
      // The regression this pins: `FileStat.stat` does not throw for an absent
      // path, it returns `type == notFound` with `size == -1`. Reading that as
      // "exists" would make every undownloaded model look present.
      final result = await probeFilePresence('${dir.path}/nope.gguf');
      expect(result, FilePresence.missing);
      expect(result.exists, isFalse);
      expect(result.length, 0);
    });
  });

  group('FilePresenceCache', () {
    late Directory dir;
    late FileCacheProbeRecorder recorder;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('presence');
      recorder = FileCacheProbeRecorder();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('serves a repeated query without touching the filesystem', () async {
      final cache = FilePresenceCache(probe: recorder.probe);

      expect(
        await cache.get('/a'),
        const FilePresence(exists: true, length: 1),
      );
      expect(
        await cache.get('/a'),
        const FilePresence(exists: true, length: 1),
      );
      expect(
        await cache.get('/a'),
        const FilePresence(exists: true, length: 1),
      );

      expect(recorder.calls, 1, reason: 'only the first call may hit the disk');
      expect(cache.probes, 1);
      expect(cache.hits, 2);
    });

    test('caches distinct paths independently', () async {
      final cache = FilePresenceCache(probe: recorder.probe);

      await cache.get('/a');
      await cache.get('/b');
      expect(recorder.calls, 2);

      await cache.get('/a');
      await cache.get('/b');
      expect(recorder.calls, 2, reason: 'each path is probed exactly once');
    });

    test('a missing file is cached too', () async {
      // "Not downloaded" is the answer for most of the catalogue, so
      // re-probing it would be the single biggest source of waste.
      recorder.setResult('/missing', FilePresence.missing);
      final cache = FilePresenceCache(probe: recorder.probe);

      expect(await cache.get('/missing'), FilePresence.missing);
      expect(await cache.get('/missing'), FilePresence.missing);
      expect(recorder.calls, 1);
    });

    test('invalidate forces the very next read back to the disk', () async {
      final cache = FilePresenceCache(probe: recorder.probe);

      expect(
        await cache.get('/a'),
        const FilePresence(exists: true, length: 1),
      );
      recorder.setResult('/a', const FilePresence(exists: false, length: 0));

      // Still the stale answer...
      expect(
        await cache.get('/a'),
        const FilePresence(exists: true, length: 1),
      );

      // ...until the write/delete path says otherwise.
      cache.invalidate('/a');
      expect(await cache.get('/a'), FilePresence.missing);
      expect(recorder.calls, 2);
    });

    test('invalidate leaves other paths cached', () async {
      final cache = FilePresenceCache(probe: recorder.probe);

      await cache.get('/a');
      await cache.get('/b');
      cache.invalidate('/a');

      await cache.get('/a');
      await cache.get('/b');
      expect(recorder.calls, 3, reason: 'only /a was re-probed');
    });

    test('clear drops everything', () async {
      final cache = FilePresenceCache(probe: recorder.probe);

      await cache.get('/a');
      await cache.get('/b');
      expect(cache.length, 2);

      cache.clear();
      expect(cache.length, 0);

      await cache.get('/a');
      await cache.get('/b');
      expect(recorder.calls, 4);
    });

    test('expires on the TTL so an external change is still noticed', () async {
      var now = DateTime(2026, 1, 1);
      final cache = FilePresenceCache(
        probe: recorder.probe,
        now: () => now,
        ttl: const Duration(seconds: 4),
      );

      await cache.get('/a');
      expect(recorder.calls, 1);

      // Just inside the window.
      now = now.add(const Duration(seconds: 3, milliseconds: 999));
      await cache.get('/a');
      expect(recorder.calls, 1);

      // At the window.
      now = now.add(const Duration(milliseconds: 2));
      await cache.get('/a');
      expect(recorder.calls, 2);
    });

    test('a zero TTL effectively disables reuse', () async {
      final cache = FilePresenceCache(
        probe: recorder.probe,
        ttl: Duration.zero,
      );

      await cache.get('/a');
      await cache.get('/a');
      await cache.get('/a');
      expect(recorder.calls, 3);
    });

    test('never grows past maxEntries', () async {
      final cache = FilePresenceCache(probe: recorder.probe);

      for (var i = 0; i < FilePresenceCache.maxEntries * 3; i++) {
        await cache.get('/path/$i');
      }

      expect(cache.length, FilePresenceCache.maxEntries);
    });

    test(
      'agrees with the real filesystem across a download-then-delete cycle',
      () async {
        // End-to-end shape of the bug this cache exists to prevent: a row is
        // asked "is it installed?" repeatedly, the file appears, and the answer
        // must flip to true without waiting for the TTL.
        final file = File('${dir.path}/model.gguf');
        final cache = FilePresenceCache();

        expect((await cache.get(file.path)).exists, isFalse);

        // "Download finished."
        file.writeAsBytesSync(List<int>.filled(2048, 1));
        cache.invalidate(file.path);

        final afterDownload = await cache.get(file.path);
        expect(afterDownload.exists, isTrue);
        expect(afterDownload.length, 2048);

        // "User deleted it."
        file.deleteSync();
        cache.invalidate(file.path);

        expect((await cache.get(file.path)).exists, isFalse);
      },
    );
  });
}

/// Records every probe so a test can assert how many syscalls were avoided, and
/// lets a test change what the "filesystem" says for a given path.
class FileCacheProbeRecorder {
  final Map<String, FilePresence> _results = {};
  final List<String> _paths = [];

  /// Every path that reached the probe, in order.
  List<String> get paths => List.unmodifiable(_paths);

  /// How many times the probe was invoked.
  int get calls => _paths.length;

  /// What the probe reports for [path] until told otherwise.
  FilePresence resultFor(String path) =>
      _results[path] ??= FilePresence(exists: true, length: _paths.length + 1);

  /// Pin the probe's answer for [path], so a test can simulate the file
  /// appearing or disappearing between two reads.
  void setResult(String path, FilePresence value) => _results[path] = value;

  Future<FilePresence> probe(String path) async {
    _paths.add(path);
    return _results[path] ?? FilePresence(exists: true, length: _paths.length);
  }
}
