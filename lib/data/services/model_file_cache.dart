/// A small, correct cache for "does this model file exist, and how big is it".
///
/// ## Why this exists
///
/// `ModelManager.isInstalled` answers a question about the filesystem, and
/// every model screen asks it once per catalogue row, on every build, from a
/// `FutureBuilder`. Scrolling the model list therefore re-`stat`s the same
/// handful of files dozens of times per second — each row doing up to six
/// `exists()`/`length()` round trips, none of which can change while the user
/// scrolls. On a phone with slow storage that is visible jank for no benefit.
///
/// The cache is deliberately boring and deliberately *not* clever:
///
///  * **keyed by absolute path**, because that is the identity of the thing
///    being asked about;
///  * **TTL-bounded**, so a file that appears or disappears out of band (a
///    download finished in another process, the user deleted it through a file
///    manager, "erase all data" removed the directory) is still noticed within
///    [_defaultTtl] rather than being cached forever;
///  * **explicitly invalidated** at every place this app writes, renames or
///    removes a model file, so the answer is *immediately* correct after an
///    action the user just took — the TTL is only a safety net for changes this
///    app did not make;
///  * **bounded in size**, so a pathological sequence of one-off paths cannot
///    grow the map without limit.
///
/// A missing file is cached as "missing" rather than being re-probed every
/// time: the overwhelming majority of rows in the catalogue are not downloaded,
/// and those are exactly the paths that would otherwise be re-stat'd forever.
///
/// This class is pure `dart:async` + `dart:io` with an injectable probe and
/// clock, so its behaviour can be unit-tested without a device, a plugin, or a
/// real download.
library;

import 'dart:async';
import 'dart:io';

/// The answer to "is this file present, and how many bytes does it hold".
class FilePresence {
  /// True when the path exists (as a file, directory or other entity — callers
  /// that care about the distinction check the length or use the entity type).
  final bool exists;

  /// Size in bytes; zero when [exists] is false.
  final int length;

  const FilePresence({required this.exists, required this.length});

  /// The answer for a path that is not there. Cached like any other result:
  /// "not downloaded" is a fact about the world, not a failure to look it up.
  static const missing = FilePresence(exists: false, length: 0);

  @override
  String toString() => 'FilePresence(exists: $exists, length: $length)';

  @override
  bool operator ==(Object other) =>
      other is FilePresence && other.exists == exists && other.length == length;

  @override
  int get hashCode => Object.hash(exists, length);
}

/// Performs the actual filesystem probe. Injectable so tests can count calls.
typedef FilePresenceProbe = Future<FilePresence> Function(String path);

/// TTL-bounded, invalidatable cache of file presence + size.
///
/// Not a general-purpose cache: it exists to collapse the repeated `isInstalled`
/// probes a scrolling list generates, and it is written so that being wrong is
/// impossible in the only way that matters (the app never sees a stale answer
/// about a file it just wrote — see [invalidate]).
class FilePresenceCache {
  /// How long a probe result may be reused without re-checking the disk.
  ///
  /// Short enough that any change made outside this app (a file manager, a
  /// background job, "erase all data") is picked up promptly, long enough that
  /// a fast scroll — dozens of builds in a couple of seconds — costs one probe
  /// per file rather than dozens.
  static const Duration defaultTtl = Duration(seconds: 4);

  /// Upper bound on cached paths.
  ///
  /// The real working set is tiny (six catalogue models, a few files each), but
  /// the cache is keyed by arbitrary strings and must not be able to grow
  /// without limit if something starts feeding it many distinct paths.
  static const int maxEntries = 64;

  /// Injected so tests get deterministic TTL expiry without sleeping.
  final DateTime Function() _now;

  final FilePresenceProbe _probe;

  final Duration _ttl;

  final Map<String, _CacheEntry> _entries = <String, _CacheEntry>{};

  /// Number of times a cached answer was served instead of a fresh probe.
  ///
  /// Exposed so the win is measurable rather than asserted, and so a test can
  /// prove the cache is actually being hit (a cache that never hits is not a
  /// cache).
  int hits = 0;

  /// Number of times the filesystem was actually probed.
  int probes = 0;

  FilePresenceCache({
    FilePresenceProbe? probe,
    DateTime Function()? now,
    Duration ttl = defaultTtl,
  }) : _probe = probe ?? probeFilePresence,
       _now = now ?? DateTime.now,
       _ttl = ttl;

  /// Presence and size of [path], reusing a recent answer when there is one.
  ///
  /// Negative TTLs are treated as "never reuse", which keeps the constructor
  /// total and makes the cache trivially switchable off.
  Future<FilePresence> get(String path) async {
    final entry = _entries[path];
    if (entry != null && !_isExpired(entry)) {
      hits++;
      return entry.presence;
    }

    probes++;
    final presence = await _probe(path);
    _store(path, presence);
    return presence;
  }

  /// Forget what we knew about [path], forcing the next [get] to probe.
  ///
  /// Called by [ModelManager] wherever it writes, renames or deletes a model
  /// file, so that the very next `isInstalled` reflects the action the user
  /// just took rather than waiting out the TTL.
  void invalidate(String path) {
    _entries.remove(path);
  }

  /// Forget everything. Used when a whole directory disappears.
  void clear() => _entries.clear();

  /// Number of cached paths. Useful in tests and diagnostics.
  int get length => _entries.length;

  bool _isExpired(_CacheEntry entry) =>
      _ttl <= Duration.zero || _now().difference(entry.at) >= _ttl;

  void _store(String path, FilePresence presence) {
    // Re-inserting moves the key to the end of the map's iteration order, which
    // makes the oldest-written entry the first eviction candidate without a
    // separate LRU structure.
    _entries.remove(path);
    _entries[path] = _CacheEntry(presence, _now());
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

class _CacheEntry {
  final FilePresence presence;
  final DateTime at;

  const _CacheEntry(this.presence, this.at);
}

/// The real filesystem probe: one `stat` where `File.exists()` + `length()`
/// used to cost two.
///
/// `FileStat.stat` raises `FileSystemException` for a missing path, which is the
/// overwhelmingly common answer in the model catalogue, so it is caught and
/// turned into [FilePresence.missing] here rather than at every call site. Any
/// other failure (permission denied, a path that is not a regular file) also
/// degrades to "missing", matching what `File.exists()` would have reported.
Future<FilePresence> probeFilePresence(String path) async {
  try {
    final stat = await FileStat.stat(path);
    return FilePresence(exists: true, length: stat.size);
  } catch (_) {
    return FilePresence.missing;
  }
}
