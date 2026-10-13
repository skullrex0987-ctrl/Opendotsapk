/// Downloads, stores, deletes and selects the on-device GGUF models.
///
/// Models live under `<app documents>/models/`. Nothing is bundled in the APK;
/// the user picks a model in Settings and the app streams it from Hugging Face
/// with live progress.
///
/// ## Why this file is defensive
///
/// A 1.9 GB download (Moondream2 is 1.06 GB of weights plus a 0.91 GB
/// projector) is a long, fragile thing to fetch on a phone. The old version
/// deleted the partial file on *any* error, so a single socket drop — a lock
/// screen, a lift ride — threw away everything and restarted from byte 0. That
/// is the "Moondream2 downloads again and again" loop.
///
/// The rules now are:
///   * every file is pinned to an immutable Hugging Face commit and carries an
///     exact size and SHA-256 in a manifest;
///   * an interrupted transfer KEEPS its `.part` file and its validators so the
///     next run can resume with an HTTP `Range`;
///   * a `.part` is only ever removed when it is provably wrong (bad checksum,
///     stale revision, or a server that refused the range) — never merely
///     because the network hiccuped;
///   * only a file whose size and SHA-256 both match the manifest is promoted to
///     its final name.
///
/// The decision logic (verification and resume planning) is deliberately kept
/// in free functions at the top of the file so it can be unit-tested without a
/// network, a device, or a real download.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart' show DartHashAlgorithm, DartHashSink;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/log.dart';
import '../../domain/models/local_model.dart';
import 'model_file_cache.dart';

// =============================================================== integrity model

/// Expected size and content hash of a single downloadable file.
class FileIntegrity {
  /// Exact size in bytes. A mismatch means the transfer is truncated/extended
  /// and the file must not be promoted.
  final int size;

  /// Lowercase hex SHA-256 of the complete file. Verified against the finished
  /// `.part` before it is renamed into place.
  final String sha256;

  const FileIntegrity(this.size, this.sha256);
}

/// The immutable identity of a model's remote files: the Hugging Face commit
/// they are pinned to, plus a per-file integrity entry.
class ModelIntegrity {
  /// 40-character lowercase hex commit. Pinning to a commit (rather than
  /// `resolve/main`) means an upstream re-tag or force-push cannot silently
  /// change the bytes we hash against.
  final String commitSha;

  /// Integrity entry per file name, matching [LocalModel.files].
  final Map<String, FileIntegrity> files;

  const ModelIntegrity({required this.commitSha, required this.files});
}

final RegExp _commitShaPattern = RegExp(r'^[0-9a-f]{40}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// True when [sha] is a plausible immutable commit id (40 lowercase hex).
bool isImmutableCommitSha(String sha) => _commitShaPattern.hasMatch(sha);

/// Manifest of every downloadable file: pinned commit + exact size + SHA-256.
///
/// Sizes are exact byte counts and hashes are the content SHA-256, both read
/// from the Hugging Face tree/LFS metadata at the pinned commit. `vocab.txt` is
/// a plain (non-LFS) file, so its hash was computed directly rather than taken
/// from an `lfs.oid`.
///
/// If a model is added to [ModelCatalog] and is not listed here, [download]
/// refuses to fetch it — failing closed is the point: a model without a
/// verified pin must not be downloaded from a mutable `main`.
const Map<String, ModelIntegrity> modelIntegrityManifest = {
  'qwen2.5-0.5b-instruct-q4_k_m': ModelIntegrity(
    commitSha: '9217f5db79a29953eb74d5343926648285ec7e67',
    files: {
      'qwen2.5-0.5b-instruct-q4_k_m.gguf': FileIntegrity(
        491400032,
        '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db',
      ),
    },
  ),
  'smollm2-360m-instruct-q8_0': ModelIntegrity(
    commitSha: '593b5a2e04c8f3e4ee880263f93e0bd2901ad47f',
    files: {
      'smollm2-360m-instruct-q8_0.gguf': FileIntegrity(
        386404992,
        '48ab3034d0dd401fbc721eb1df3217902fee7dab9078992d66431f09b7750201',
      ),
    },
  ),
  'qwen2.5-1.5b-instruct-q4_k_m': ModelIntegrity(
    commitSha: '91cad51170dc346986eccefdc2dd33a9da36ead9',
    files: {
      'qwen2.5-1.5b-instruct-q4_k_m.gguf': FileIntegrity(
        1117320736,
        '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
      ),
    },
  ),
  // Qwen3.5 0.8B — the vision model that actually loads. Pin read from the
  // Hugging Face tree API at this exact commit; the LFS `oid` is the SHA-256.
  'qwen3.5-0.8b-q4_k_m': ModelIntegrity(
    commitSha: '6ab461498e2023f6e3c1baea90a8f0fe38ab64d0',
    files: {
      'Qwen3.5-0.8B-Q4_K_M.gguf': FileIntegrity(
        532517120,
        'bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517',
      ),
      'mmproj-F16.gguf': FileIntegrity(
        204987232,
        '56e4c6cfe73b0c82e3e82bc518d7591997e61d81f723fc41a586f4fa69ea2453',
      ),
    },
  ),
  // SmolVLM-500M — smallest vision model; Q4_K_M keeps it under 500 MB total.
  'smolvlm-500m-instruct-q4_k_m': ModelIntegrity(
    commitSha: '4c1ae1b9c70b72e7064e350f705883abf492d392',
    files: {
      'SmolVLM-500M-Instruct-Q4_K_M.gguf': FileIntegrity(
        303251712,
        '0036ee911a27da7d039e084f2d2c32b9976c81d9dde8945811ed589a3099bca8',
      ),
      'mmproj-SmolVLM-500M-Instruct-f16.gguf': FileIntegrity(
        199468864,
        'a361f1d5248b7569e3ad8703b8f42b18937a60d8871baf876dda182d29ec1a72',
      ),
    },
  ),
  // InternVL2.5-1B — good vision quality at ~1.1 GB total (Q4_K_M).
  'internvl2_5-1b-q4_k_m': ModelIntegrity(
    commitSha: '1cfc92b0d2a4f2394c757606103aa5c010b31e7f',
    files: {
      'InternVL2_5-1B.Q4_K_M.gguf': FileIntegrity(
        490984416,
        '4c20ea78f1b3e5eb19ce6dbfdcf9ec717d6643e995de06d9632fcb751f30d0a7',
      ),
      'InternVL2_5-1B.mmproj-f16.gguf': FileIntegrity(
        619876960,
        '0c672edd99ec0b99df01c75dbb6cc26ad2236d7d61f908c93b5fda9b4d9ddd20',
      ),
    },
  ),
  'all-minilm-l6-v2': ModelIntegrity(
    commitSha: '1110a243fdf4706b3f48f1d95db1a4f5529b4d41',
    files: {
      'minilm-l6-v2.onnx': FileIntegrity(
        90405214,
        '6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452',
      ),
      'vocab.txt': FileIntegrity(
        231508,
        '07eced375cec144d27c900241f3e339478dec958f92fddbc551f295c992038a3',
      ),
    },
  ),
};

/// Integrity entry for [m], or null when the model is not pinned.
ModelIntegrity? integrityFor(LocalModel m) => modelIntegrityManifest[m.id];

/// Rewrites a Hugging Face `resolve/main` URL onto an immutable commit.
///
/// Throws [ArgumentError] when [commitSha] is not a 40-char hex commit, when
/// the URL still points at `main`, or when it is not a resolvable HF URL. A
/// throw is intentional: it is better to fail the download than to quietly
/// fetch whatever `main` happens to be today.
String pinToCommit(String url, String commitSha) {
  if (!_commitShaPattern.hasMatch(commitSha)) {
    throw ArgumentError.value(
      commitSha,
      'commitSha',
      'must be a 40-char lowercase hex commit',
    );
  }
  const marker = '/resolve/main/';
  if (url.contains(marker)) {
    return url.replaceFirst(marker, '/resolve/$commitSha/');
  }
  if (url.contains('/resolve/')) {
    return url; // already pinned to a specific revision
  }
  throw ArgumentError.value(url, 'url', 'not a Hugging Face resolve URL');
}

// =============================================================== verification

/// Why a finished `.part` was accepted or rejected.
enum DownloadVerdict {
  ok,

  /// Zero bytes arrived — an "empty" 200 body or a fully-failed transfer.
  empty,

  /// Fewer bytes than the file's expected size (or than Content-Length).
  truncated,

  /// More bytes than expected; the manifest pin does not match the remote.
  oversized,

  /// The content hash does not match the manifest.
  checksumMismatch,

  /// The manifest has no usable SHA-256, so nothing can be trusted.
  missingChecksum,

  /// The manifest has no usable size, so nothing can be trusted.
  badExpectedSize,
}

/// Typed result of [verifyDownload]. [message] is user-facing.
class DownloadVerification {
  final DownloadVerdict verdict;
  final String message;

  const DownloadVerification(this.verdict, this.message);

  bool get ok => verdict == DownloadVerdict.ok;

  @override
  String toString() => 'DownloadVerification(${verdict.name}: $message)';
}

/// Decide whether a finished file may be promoted, from plain values only.
///
/// [receivedBytes] is the size of the complete finished `.part` (for a resumed
/// download that is the *total* size, not just the bytes fetched this run).
/// [contentLength] should be the server's Content-Length for a response that
/// carried the whole file, or null when it is unknown or describes only a
/// partial (206) body.
///
/// This is pure on purpose: the same decision the downloader makes is the one
/// the tests exercise, with no I/O in between.
DownloadVerification verifyDownload({
  required int receivedBytes,
  required int expectedSize,
  required String? expectedSha256,
  required String? actualSha256,
  int? contentLength,
}) {
  if (receivedBytes <= 0) {
    return const DownloadVerification(
      DownloadVerdict.empty,
      'no bytes were received',
    );
  }
  if (expectedSize <= 0) {
    return const DownloadVerification(
      DownloadVerdict.badExpectedSize,
      'provider has no expected size',
    );
  }
  final expected = expectedSha256?.toLowerCase();
  if (expected == null || !_sha256Pattern.hasMatch(expected)) {
    // Fail closed: without a pinned hash a "successful" download proves nothing.
    return const DownloadVerification(
      DownloadVerdict.missingChecksum,
      'provider has no usable SHA-256',
    );
  }
  // A server that promised N bytes and delivered fewer truncated the body.
  if (contentLength != null &&
      contentLength > 0 &&
      receivedBytes != contentLength) {
    return DownloadVerification(
      DownloadVerdict.truncated,
      'received $receivedBytes of a promised $contentLength bytes',
    );
  }
  if (receivedBytes < expectedSize) {
    return DownloadVerification(
      DownloadVerdict.truncated,
      'received $receivedBytes of $expectedSize bytes',
    );
  }
  if (receivedBytes > expectedSize) {
    return DownloadVerification(
      DownloadVerdict.oversized,
      'received $receivedBytes, more than the expected $expectedSize bytes',
    );
  }
  final actual = actualSha256?.toLowerCase();
  if (actual == null) {
    return const DownloadVerification(
      DownloadVerdict.checksumMismatch,
      'checksum could not be computed',
    );
  }
  if (actual != expected) {
    return DownloadVerification(
      DownloadVerdict.checksumMismatch,
      'SHA-256 mismatch (expected $expected, got $actual)',
    );
  }
  return const DownloadVerification(DownloadVerdict.ok, 'ok');
}

// =============================================================== resume logic

/// Compute the strongest validator available for an interrupted download.
///
/// An ETag is preferred over Last-Modified: a Last-Modified timestamp has
/// one-second resolution and two different files can share it.
String? resumeValidator({String? etag, String? lastModified}) {
  final e = etag?.trim();
  if (e != null && e.isNotEmpty) return e;
  final l = lastModified?.trim();
  if (l != null && l.isNotEmpty) return l;
  return null;
}

/// What to do with a `.part` that already exists on disk.
class ResumePlan {
  /// First byte to request. Zero for a clean start.
  final int startByte;

  /// True when the partial must be discarded (or there is nothing to resume).
  final bool restart;

  /// Extra headers to send — `Range` and `If-Range` when resuming.
  final Map<String, String> headers;

  /// Why the plan turned out this way, for logs.
  final String? reason;

  const ResumePlan({
    required this.startByte,
    required this.restart,
    this.headers = const {},
    this.reason,
  });

  /// True when a byte range will be requested from an existing partial.
  bool get isResume => !restart && startByte > 0;
}

/// Decide how to continue a download given the partial on disk and what we know
/// about the server.
///
/// A resume is only attempted when it is *safe*: the server may serve ranges,
/// the partial is smaller than the full file, and we hold a validator from the
/// interrupted session so `If-Range` can detect an upstream revision change.
/// Anything else restarts cleanly rather than splicing two different files.
ResumePlan planResume({
  required int existingBytes,
  required int expectedSize,
  bool? acceptRangesBytes,
  String? storedEtag,
  String? storedLastModified,
  int? storedExpectedSize,
}) {
  if (existingBytes <= 0) {
    return const ResumePlan(
      startByte: 0,
      restart: true,
      reason: 'no partial file',
    );
  }
  if (expectedSize > 0 && existingBytes >= expectedSize) {
    // Nothing left to fetch, and the bytes still have to pass verification.
    return const ResumePlan(
      startByte: 0,
      restart: true,
      reason: 'partial already covers the file',
    );
  }
  if (storedExpectedSize != null &&
      expectedSize > 0 &&
      storedExpectedSize != expectedSize) {
    // The pinned size changed since the partial was written (a new manifest):
    // the partial belongs to a different file, so start over.
    return const ResumePlan(
      startByte: 0,
      restart: true,
      reason: 'partial was for a different size',
    );
  }
  if (acceptRangesBytes == false) {
    return const ResumePlan(
      startByte: 0,
      restart: true,
      reason: 'server does not advertise Accept-Ranges: bytes',
    );
  }
  final validator = resumeValidator(
    etag: storedEtag,
    lastModified: storedLastModified,
  );
  if (validator == null) {
    // Without a validator we cannot detect that the remote changed, so an
    // append could stitch two revisions into one corrupt file.
    return const ResumePlan(
      startByte: 0,
      restart: true,
      reason: 'no stored validator',
    );
  }
  return ResumePlan(
    startByte: existingBytes,
    restart: false,
    reason: 'resume from byte $existingBytes',
    headers: {
      'Range': 'bytes=$existingBytes-',
      // If the file changed since the partial was written, the server ignores
      // the Range and answers 200 with the whole file — we then restart.
      'If-Range': validator,
    },
  );
}

/// How to treat the response to a ranged request.
enum RangeVerdict { resume, restart }

/// Classify a response to a request that carried a `Range` header.
///
/// Only a 206 whose Content-Range starts exactly where we asked may be appended
/// to the partial. A 200 (range ignored, or If-Range rejected a stale
/// validator) or a 206 from a different offset means the partial cannot be
/// trusted and the transfer must start over from zero.
RangeVerdict interpretRangedGet({
  required int statusCode,
  required int requestedStart,
  int? contentRangeStart,
}) {
  if (statusCode == 206 && contentRangeStart == requestedStart) {
    return RangeVerdict.resume;
  }
  return RangeVerdict.restart;
}

// =============================================================== hashing

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// SHA-256 of [bytes], lowercase hex.
///
/// Synchronous and dependency-light so it can be checked against the published
/// NIST vectors in a unit test.
String sha256HexOfBytes(List<int> bytes) {
  final DartHashAlgorithm algorithm = Sha256().toSync();
  final DartHashSink sink = algorithm.newHashSink();
  sink.add(bytes);
  sink.close();
  return _toHex(sink.hashSync().bytes);
}

/// SHA-256 of a file, read in chunks, lowercase hex.
///
/// Uses the pure-Dart incremental sink (`Sha256().newHashSink()` buffers the
/// whole input in memory; `toSync().newHashSink()` does not), so hashing a 1 GB
/// GGUF verifies it without holding 1 GB of it in RAM.
///
/// ## Why this runs on a background isolate
///
/// Measured on a desktop x86 core with the same pure-Dart implementation this
/// file uses, SHA-256 runs at roughly **25 MiB/s**. That makes the cost of
/// verifying one of this app's own pinned downloads:
///
/// | file | size | CPU on the calling isolate |
/// |------|------|----------------------------|
/// | qwen2.5-0.5b q4_k_m | 469 MiB | ~20 s |
/// | qwen3.5-0.8b (weights + mmproj) | 703 MiB | ~28 s |
/// | moondream2 (weights + mmproj) | 1878 MiB | ~75 s |
///
/// Pure-Dart hashing is straight-line synchronous CPU work: every microtask
/// between chunks waits behind it, so the UI isolate cannot paint, cannot
/// process a frame callback, and cannot even start laying out the progress bar
/// the user is watching — for the entire verification step, which happens on
/// *every* completed download. The download progress UI freezes at 100% for
/// tens of seconds and the system may ANR.
///
/// [Isolate.run] moves the identical work onto a worker isolate, so the UI
/// stays responsive and the progress screen keeps animating while it runs.
/// The signature, the digest, and the verification semantics are unchanged:
/// `_hashFileInIsolate` is a top-level function (the only shape that can cross
/// an isolate boundary) and returns exactly what the inline version did.
Future<String> sha256HexOfFile(String path) =>
    Isolate.run(() => _hashFileInIsolate(path));

/// Read [path] and return its SHA-256 as lowercase hex.
///
/// Top-level and synchronous so it can be handed to [Isolate.run]; the only
/// thing that crosses the boundary is the path (a `String`, which is sendable)
/// and the resulting digest.
String _hashFileInIsolate(String path) {
  final DartHashAlgorithm algorithm = Sha256().toSync();
  final DartHashSink sink = algorithm.newHashSink();

  // 256 KiB per read: large enough that the syscall cost disappears next to
  // the hashing, small enough that peak memory stays trivial on a phone.
  final raf = File(path).openSync();
  try {
    while (true) {
      final chunk = raf.readSync(_hashChunkBytes);
      if (chunk.isEmpty) break;
      sink.add(chunk);
    }
  } finally {
    raf.closeSync();
  }

  sink.close();
  return _toHex(sink.hashSync().bytes);
}

/// Read size used by [sha256HexOfFile].
const int _hashChunkBytes = 256 * 1024;

// =============================================================== free space

/// Returns free bytes on the volume holding [path], or null when unknown.
typedef FreeSpaceProbe = Future<int?> Function(String path);

/// Pluggable free-space probe; null means "cannot read free space here".
///
/// It is null by default: `dart:io` exposes per-file [FileStat] but not
/// filesystem free space, and this project has no `statfs`-style package or
/// MethodChannel for it. The pre-download check therefore logs the shortfall
/// risk and proceeds rather than blocking every download on a value it cannot
/// read. Supplying a real probe (from a future platform binding) enables the
/// check; this is the one remaining gap in the download path.
FreeSpaceProbe? freeSpaceProbe;

// =============================================================== progress event

/// Progress event emitted while downloading a model.
class DownloadProgress {
  final String modelId;
  final int received;
  final int total;
  final String currentFile;
  final bool done;
  final String? error;

  const DownloadProgress({
    required this.modelId,
    required this.received,
    required this.total,
    required this.currentFile,
    this.done = false,
    this.error,
  });

  /// 0.0 - 1.0, or null when the server did not send Content-Length.
  double? get fraction {
    if (total <= 0) return null;
    return (received / total).clamp(0.0, 1.0);
  }

  String get receivedLabel => _fmt(received);
  String get totalLabel => _fmt(total);

  static String _fmt(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}

// =============================================================== part metadata

/// Validators remembered alongside a `.part` so the next run can resume safely.
class _PartMeta {
  final String? etag;
  final String? lastModified;

  /// Null means the server never advertised Accept-Ranges (e.g. a 206 response
  /// that omits it), so we don't know — treat as "maybe" rather than "no".
  final bool? acceptRanges;
  final int expectedSize;

  const _PartMeta({
    this.etag,
    this.lastModified,
    this.acceptRanges,
    required this.expectedSize,
  });

  Map<String, dynamic> toJson() => {
    'etag': etag,
    'last_modified': lastModified,
    'accept_ranges': acceptRanges,
    'expected_size': expectedSize,
  };

  static _PartMeta? fromJson(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return _PartMeta(
        etag: j['etag'] as String?,
        lastModified: j['last_modified'] as String?,
        acceptRanges: j['accept_ranges'] as bool?,
        expectedSize: (j['expected_size'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // A corrupt sidecar just means "no validators" — restart cleanly.
      return null;
    }
  }
}

// =============================================================== manager

class ModelManager {
  static ModelManager? _instance;
  ModelManager._();

  static ModelManager getInstance() => _instance ??= ModelManager._();

  static const Duration _connectTimeout = Duration(seconds: 30);

  /// No byte for this long aborts the transfer with a typed error instead of
  /// hanging forever on a half-open socket. The `.part` is kept, so a retry
  /// resumes rather than restarting.
  static const Duration _inactivityTimeout = Duration(seconds: 45);

  /// Headroom left free on top of the model size, so a download cannot fill the
  /// volume to the last byte.
  static const int _freeSpaceReserve = 64 * 1024 * 1024;

  /// Cached "does this file exist, and how big is it" answers.
  ///
  /// Every model screen asks [isInstalled] once per catalogue row on every
  /// build, so a scrolling list re-stats the same files dozens of times for an
  /// answer that cannot have changed. See `model_file_cache.dart` for the TTL
  /// and invalidation contract; every write/rename/delete below invalidates
  /// the exact path it touched.
  final FilePresenceCache _fileCache = FilePresenceCache();

  /// Resolved once per process.
  ///
  /// `getApplicationDocumentsDirectory()` is a platform-channel round trip, and
  /// [isInstalled] used to call it once *per file* rather than once per model —
  /// so a single row could cost four channel calls before touching the disk.
  /// The documents directory cannot move while the app runs, so it is asked
  /// once and reused. [clearFileCache] drops this along with the file cache when
  /// the whole models directory is removed underneath us.
  String? _modelsDirPath;

  /// Exposed so diagnostics can see how much redundant probing is being
  /// avoided, and so a test can assert the cache is actually being used.
  ///
  /// Deliberately a plain getter rather than a `@visibleForTesting` member:
  /// this is a pure-Dart data-layer file and does not otherwise depend on
  /// Flutter, and a test may legitimately hold on to it.
  FilePresenceCache get fileCache => _fileCache;

  /// Directory that holds all downloaded models.
  Future<Directory> modelsDir() async {
    final cached = _modelsDirPath;
    if (cached != null) {
      final dir = Directory(cached);
      // The directory itself can vanish ("erase all data" deletes it), so the
      // cheap existence check stays even though the path is memoised.
      if (await dir.exists()) return dir;
      _modelsDirPath = null;
    }

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, AppConstants.modelsDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _modelsDirPath = dir.path;
    return dir;
  }

  /// Drop every cached filesystem answer and the memoised models directory.
  ///
  /// The TTL means a stale answer is never permanent, but when the whole models
  /// directory is deleted at once (Erase all data) re-resolving the path costs
  /// one channel call and removes any chance of answering from a cache entry
  /// for a file that no longer exists.
  void clearFileCache() {
    _fileCache.clear();
    _modelsDirPath = null;
  }

  Future<String> pathForFile(String fileName) async {
    final dir = await modelsDir();
    return p.join(dir.path, fileName);
  }

  /// Absolute path of a model's main weight file (whether or not it exists).
  Future<String> weightPath(LocalModel m) => pathForFile(m.fileName);

  /// Absolute path of a vision model's projector, or null for text models.
  Future<String?> projectorPath(LocalModel m) async {
    final name = m.projectorFileName;
    if (name == null) return null;
    return pathForFile(name);
  }

  /// Per-file completeness floors. Weights need megabytes; `vocab.txt` is only
  /// ~227 KB and a flat 1 MB check would treat it as permanently missing.
  static Map<String, int> _floorsFor(LocalModel m) => <String, int>{
    m.fileName: m.minBytes,
    if (m.projectorFileName != null) m.projectorFileName!: m.minBytes,
    for (final f in m.extraFiles) f.name: f.minBytes,
  };

  /// True when every file the model needs is present on disk and complete.
  ///
  /// When a manifest entry exists its exact size is authoritative (a file that
  /// is the wrong size is not installed, however large it is); otherwise the
  /// coarser per-file floor is used.
  ///
  /// Resolves the models directory once and then answers every file from
  /// [_fileCache], so a rebuild of a list of rows costs one directory lookup
  /// and no syscalls at all while the cache is warm.
  Future<bool> isInstalled(LocalModel m) async {
    final floors = _floorsFor(m);
    final integrity = integrityFor(m);
    final dir = await modelsDir();

    for (final f in m.files) {
      final path = p.join(dir.path, f.name);
      final stat = await _fileCache.get(path);
      if (!stat.exists) return false;
      final expected = integrity?.files[f.name]?.size;
      if (expected != null) {
        if (stat.length != expected) return false;
      } else if (stat.length < (floors[f.name] ?? m.minBytes)) {
        return false;
      }
    }
    return true;
  }

  /// Total bytes currently used by installed models.
  Future<int> installedBytes() async {
    final dir = await modelsDir();
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File &&
          (entity.path.endsWith('.gguf') || entity.path.endsWith('.onnx'))) {
        total += await entity.length();
      }
    }
    return total;
  }

  /// Delete a model's files (main + projector). Any stray `.part`/`.part.meta`
  /// for the model is removed too, so a delete really means "gone".
  Future<void> delete(LocalModel m) async {
    for (final f in m.files) {
      for (final suffix in const ['', '.part', '.part.meta']) {
        final file = File('${await pathForFile(f.name)}$suffix');
        // The cache must not survive the removal: the whole point of deleting a
        // model is that the row immediately reads as "not downloaded".
        _fileCache.invalidate(file.path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    // Clear the selection if the deleted model was active.
    if (await activeLlmId() == m.id) await setActiveLlmId(null);
    if (await activeVisionId() == m.id) await setActiveVisionId(null);
    if (await activeEmbeddingId() == m.id) await setActiveEmbeddingId(null);
    // Also remove from multi-selection lists if present.
    final llmIds = await activeLlmIds();
    if (llmIds.contains(m.id)) {
      await setActiveLlmIds(llmIds.where((id) => id != m.id).toList());
    }
    final visionIds = await activeVisionIds();
    if (visionIds.contains(m.id)) {
      await setActiveVisionIds(visionIds.where((id) => id != m.id).toList());
    }
    final embedIds = await activeEmbeddingIds();
    if (embedIds.contains(m.id)) {
      await setActiveEmbeddingIds(embedIds.where((id) => id != m.id).toList());
    }
  }

  /// Download a model, emitting progress until complete.
  ///
  /// Each file is fetched to `<name>.part`, verified against its manifest entry
  /// (exact size + SHA-256), and only then renamed to its final name — so an
  /// interrupted or corrupt download never leaves a file that [isInstalled]
  /// would accept. Interruptions keep the `.part` for a later resume.
  ///
  /// The returned stream's shape is unchanged from previous versions: progress
  /// events, then exactly one terminal event with either `done: true` or a
  /// non-null `error`.
  Stream<DownloadProgress> download(LocalModel m) {
    final controller = StreamController<DownloadProgress>();
    // Fire-and-forget: the pipeline reports everything through the controller.
    unawaited(_runDownload(m, controller));
    return controller.stream;
  }

  Future<void> _runDownload(
    LocalModel m,
    StreamController<DownloadProgress> controller,
  ) async {
    final approxTotal = m.approxBytes;

    void emit(
      int received,
      int total,
      String file, {
      bool done = false,
      String? error,
    }) {
      if (controller.isClosed) return;
      try {
        controller.add(
          DownloadProgress(
            modelId: m.id,
            received: received,
            total: total,
            currentFile: file,
            done: done,
            error: error,
          ),
        );
      } catch (_) {
        // The listener went away mid-download; nothing useful to do.
      }
    }

    try {
      final integrity = integrityFor(m);
      if (integrity == null || !isImmutableCommitSha(integrity.commitSha)) {
        // Fail closed: no pin means no verified download.
        emit(
          0,
          approxTotal,
          m.fileName,
          error:
              'No pinned integrity manifest for ${m.id}; refusing to '
              'download from a mutable URL.',
        );
        return;
      }

      final dir = await modelsDir();
      final expectedTotal = integrity.files.values.fold<int>(
        0,
        (a, f) => a + f.size,
      );

      // --- free space -------------------------------------------------------
      final missing = <({String name, String url, int size})>[];
      var haveBytes = 0;
      for (final f in m.files) {
        final entry = integrity.files[f.name];
        if (entry == null) {
          emit(
            0,
            approxTotal,
            f.name,
            error:
                'Manifest is missing an entry for ${f.name}; refusing to '
                'download.',
          );
          return;
        }
        final target = File(await pathForFile(f.name));
        if (await target.exists() && await target.length() == entry.size) {
          haveBytes += entry.size; // already have a verified copy
          continue;
        }
        missing.add((name: f.name, url: f.url, size: entry.size));
      }

      final needed = expectedTotal - haveBytes;
      if (needed > 0) {
        final probe = freeSpaceProbe;
        final free = probe == null ? null : await probe(dir.path);
        if (free == null) {
          Log.w(
            'ModelManager: free space unknown on this platform; skipping '
            'the pre-download check (need ~$needed bytes for ${m.id}).',
          );
        } else if (free < needed + _freeSpaceReserve) {
          emit(
            0,
            approxTotal,
            m.fileName,
            error:
                'Not enough free space: need '
                '${needed + _freeSpaceReserve} bytes, have $free.',
          );
          return;
        }
      }

      if (missing.isEmpty) {
        emit(expectedTotal, expectedTotal, m.fileName, done: true);
        return;
      }

      // --- fetch each missing file ------------------------------------------
      var baseBytes = haveBytes;
      var allOk = true;
      for (final f in missing) {
        final entry = integrity.files[f.name]!;
        final ok = await _fetchOne(
          url: f.url,
          fileName: f.name,
          entry: entry,
          commitSha: integrity.commitSha,
          dir: dir,
          onProgress: (fileReceived) =>
              emit(baseBytes + fileReceived, expectedTotal, f.name),
          onError: (msg) => emit(baseBytes, expectedTotal, f.name, error: msg),
        );
        if (!ok) {
          allOk = false;
          break;
        }
        baseBytes += entry.size;
      }

      if (allOk) {
        emit(expectedTotal, expectedTotal, m.fileName, done: true);
      }
    } catch (e) {
      emit(0, approxTotal, m.fileName, error: 'Download failed: $e');
    } finally {
      if (!controller.isClosed) await controller.close();
    }
  }

  /// Fetch one file to its `.part`, verify it, and promote it. Returns false on
  /// any failure (after emitting an error via [onError]).
  Future<bool> _fetchOne({
    required String url,
    required String fileName,
    required FileIntegrity entry,
    required String commitSha,
    required Directory dir,
    required void Function(int fileReceived) onProgress,
    required void Function(String message) onError,
  }) async {
    final target = File(p.join(dir.path, fileName));
    final partPath = '${target.path}.part';
    final part = File(partPath);
    final meta = File('$partPath.meta');

    // A full-size final file was SHA-verified before it was promoted, so a
    // matching size is enough to trust it without re-hashing 1 GB.
    if (await target.exists()) {
      if (await target.length() == entry.size) {
        onProgress(entry.size);
        return true;
      }
      await _deleteQuietly(target); // wrong size — stale/corrupt
      // The file this download is about to produce no longer has a cached
      // "present" answer, and its replacement will have a different size.
      _fileCache.invalidate(target.path);
    }

    final pinnedUrl = pinToCommit(url, commitSha);

    // Two attempts: the first may use a range, the second is the clean restart
    // taken when a range turns out to be unusable.
    for (var attempt = 1; attempt <= 2; attempt++) {
      final existing = await _lengthOrZero(part);
      final stored = await _readMeta(meta);
      final plan = planResume(
        existingBytes: existing,
        expectedSize: entry.size,
        acceptRangesBytes: stored?.acceptRanges,
        storedEtag: stored?.etag,
        storedLastModified: stored?.lastModified,
        storedExpectedSize: stored?.expectedSize,
      );

      if (plan.restart && existing > 0) {
        // Discarding here is deliberate only for a *stale* partial (no
        // validator, wrong revision, or already full) — never for a plain
        // network drop, which is handled in the catch below.
        await _deleteQuietly(part);
        await _deleteQuietly(meta);
      }

      final client = http.Client();
      IOSink? sink;
      var fileReceived = plan.restart ? 0 : plan.startByte;
      try {
        final request = http.Request('GET', Uri.parse(pinnedUrl));
        if (!plan.restart) request.headers.addAll(plan.headers);

        final response = await client.send(request).timeout(_connectTimeout);

        if (response.statusCode != 200 && response.statusCode != 206) {
          if (response.statusCode == 416) {
            // "Range Not Satisfiable": our partial is not a valid prefix of the
            // remote file (it is already as large/larger). Drop it and take the
            // clean path rather than retrying the same failing range forever.
            await response.stream.drain();
            client.close();
            await _deleteQuietly(part);
            await _deleteQuietly(meta);
            continue;
          }
          client.close();
          onError('Server returned HTTP ${response.statusCode} for $fileName');
          return false;
        }

        var append = false;
        if (response.statusCode == 206) {
          final rangeStart = _parseContentRangeStart(
            response.headers['content-range'],
          );
          final usable =
              !plan.restart &&
              plan.startByte > 0 &&
              interpretRangedGet(
                    statusCode: 206,
                    requestedStart: plan.startByte,
                    contentRangeStart: rangeStart,
                  ) ==
                  RangeVerdict.resume;
          if (usable) {
            append = true;
          } else {
            // A 206 we did not ask for, or from an unexpected offset: drop it
            // and take the clean path.
            await response.stream.drain();
            client.close();
            await _deleteQuietly(part);
            await _deleteQuietly(meta);
            continue;
          }
        } else {
          // 200: a normal fresh transfer, or the server ignored our Range (or
          // If-Range rejected a stale validator). Either way the body starts at
          // byte 0, so any partial is now stale and must go.
          if (existing > 0) {
            await _deleteQuietly(part);
            await _deleteQuietly(meta);
          }
          fileReceived = 0;
        }

        final isWholeBody = !append && response.statusCode == 200;

        // Persist the validators now, so an interruption can be resumed.
        await _writeMeta(
          meta,
          _PartMeta(
            etag: response.headers['etag'],
            lastModified: response.headers['last-modified'],
            acceptRanges: _acceptsRanges(response.headers['accept-ranges']),
            expectedSize: entry.size,
          ),
        );

        sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);

        // The inactivity timeout turns a stalled socket into a typed error
        // instead of a download that hangs for hours.
        await for (final chunk in response.stream.timeout(_inactivityTimeout)) {
          sink.add(chunk);
          fileReceived += chunk.length;
          onProgress(fileReceived);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        client.close();

        final finalLength = await _lengthOrZero(part);
        final verification = verifyDownload(
          receivedBytes: finalLength,
          expectedSize: entry.size,
          // For a 206 the Content-Length is only the remaining bytes, so it
          // must not be compared against the whole-file size.
          contentLength: isWholeBody ? response.contentLength : null,
          expectedSha256: entry.sha256,
          actualSha256: await sha256HexOfFile(part.path),
        );
        if (!verification.ok) {
          if (verification.verdict == DownloadVerdict.truncated) {
            // A short file is a valid *prefix* of the real one, so keep it and
            // its validators for the next run to resume — deleting here would
            // recreate the endless-restart loop for exactly this model.
            onError(
              '$fileName incomplete (${verification.message}); progress '
              'kept, retry to resume.',
            );
            return false;
          }
          // Wrong bytes at the right size, or the wrong length entirely: the
          // partial cannot be trusted or resumed, so keep nothing.
          await _deleteQuietly(part);
          await _deleteQuietly(meta);
          _fileCache.invalidate(target.path);
          onError('$fileName failed integrity check: ${verification.message}');
          return false;
        }

        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        // The promotion is the moment the model's identity changes on disk:
        // the file that `isInstalled` will be asked about now exists, with the
        // size the manifest pinned. Invalidate both paths so the very next
        // `isInstalled` reports the truth rather than the pre-download answer.
        _fileCache.invalidate(target.path);
        _fileCache.invalidate(partPath);
        await _deleteQuietly(meta);
        onProgress(entry.size);
        return true;
      } catch (e) {
        // Network/timeout failure: KEEP the `.part` and its validators so the
        // next run resumes instead of re-downloading from zero. Deleting here
        // was the original "downloads again and again" bug.
        try {
          await sink?.close();
        } catch (_) {}
        client.close();
        if (e is TimeoutException) {
          onError(
            'Download stalled (no data for '
            '${_inactivityTimeout.inSeconds}s); progress kept, retry to '
            'resume.',
          );
        } else {
          onError('Download interrupted: $e (progress kept, retry to resume)');
        }
        return false;
      }
    }

    onError('Could not download $fileName after retrying.');
    return false;
  }

  // ------------------------------------------------------------- selection
  Future<String?> activeLlmId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefActiveLlmId);
  }

  Future<void> setActiveLlmId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(AppConstants.prefActiveLlmId);
    } else {
      await prefs.setString(AppConstants.prefActiveLlmId, id);
    }
  }

  Future<List<String>> activeLlmIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.prefActiveLlmIds);
    return raw ?? [];
  }

  Future<void> setActiveLlmIds(List<String?> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = ids.whereType<String>().toList();
    if (cleaned.isEmpty) {
      await prefs.remove(AppConstants.prefActiveLlmIds);
    } else {
      await prefs.setStringList(AppConstants.prefActiveLlmIds, cleaned);
    }
  }

  Future<String?> activeVisionId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefActiveVisionId);
  }

  Future<void> setActiveVisionId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(AppConstants.prefActiveVisionId);
    } else {
      await prefs.setString(AppConstants.prefActiveVisionId, id);
    }
  }

  Future<List<String>> activeVisionIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.prefActiveVisionIds);
    return raw ?? [];
  }

  Future<void> setActiveVisionIds(List<String?> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = ids.whereType<String>().toList();
    if (cleaned.isEmpty) {
      await prefs.remove(AppConstants.prefActiveVisionIds);
    } else {
      await prefs.setStringList(AppConstants.prefActiveVisionIds, cleaned);
    }
  }

  Future<String?> activeEmbeddingId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(AppConstants.prefActiveEmbeddingId);
  }

  Future<void> setActiveEmbeddingId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(AppConstants.prefActiveEmbeddingId);
    } else {
      await prefs.setString(AppConstants.prefActiveEmbeddingId, id);
    }
  }

  Future<List<String>> activeEmbeddingIds() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(AppConstants.prefActiveEmbeddingIds);
    return raw ?? [];
  }

  Future<void> setActiveEmbeddingIds(List<String?> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = ids.whereType<String>().toList();
    if (cleaned.isEmpty) {
      await prefs.remove(AppConstants.prefActiveEmbeddingIds);
    } else {
      await prefs.setStringList(AppConstants.prefActiveEmbeddingIds, cleaned);
    }
  }

  Future<void> selectLlm(String id) async {
    await setActiveLlmId(id);
    final old = await activeLlmIds();
    await setActiveLlmIds([id, ...old.where((x) => x != id)]);
  }

  Future<void> selectVision(String? id) async {
    await setActiveVisionId(id);
    if (id == null) {
      await setActiveVisionIds(const <String>[]);
    } else {
      final old = await activeVisionIds();
      await setActiveVisionIds([id, ...old.where((x) => x != id)]);
    }
  }

  /// The active chat model, falling back to the default when unset/missing.
  ///
  /// Two traps this must not fall into, both of which made the Load button
  /// appear dead:
  ///
  /// 1. `kind == ModelKind.llm` alone rejected Qwen3.5, which is registered as
  ///    `vision` with [LocalModel.isMultimodal]. Selecting it as the chat model
  ///    therefore *silently* fell back to the default LLM — a model the user
  ///    had never downloaded — so Load reported "No chat model downloaded yet"
  ///    no matter how many times it was tapped. Multimodal models are chat
  ///    models too, so `isMultimodal` counts.
  /// 2. Falling back to a fixed catalog default is only safe when that default
  ///    is on disk. Prefer the first *installed* chat model; the catalog
  ///    default is the last resort, and the caller then reports it honestly
  ///    rather than pretending the selection took.
  Future<LocalModel> activeLlm() async {
    final ids = await activeLlmIds();
    Log.d('ModelManager.activeLlm: prefActiveLlmIds = $ids');
    for (final id in ids) {
      final m = ModelCatalog.byId(id);
      if (m != null && ModelCatalog.isChatCapable(m) && await isInstalled(m)) {
        Log.d('ModelManager.activeLlm: returning selected model ${m.id}');
        return m;
      }
    }
    // fallback to single legacy key
    final legacyId = await activeLlmId();
    if (legacyId != null) {
      final m = ModelCatalog.byId(legacyId);
      if (m != null && ModelCatalog.isChatCapable(m) && await isInstalled(m)) {
        Log.d(
          'ModelManager.activeLlm: returning legacy selected model ${m.id}',
        );
        return m;
      }
    }
    Log.d(
      'ModelManager.activeLlm: selected model not found/not installed, checking installed llms',
    );
    for (final candidate in ModelCatalog.llms) {
      if (await isInstalled(candidate)) {
        Log.d(
          'ModelManager.activeLlm: returning installed candidate ${candidate.id}',
        );
        return candidate;
      }
    }
    Log.d(
      'ModelManager.activeLlm: no installed models, returning default ${ModelCatalog.defaultLlm.id}',
    );
    return ModelCatalog.defaultLlm;
  }

  /// The active vision model, or null when none is installed/selected.
  Future<LocalModel?> activeVision() async {
    final ids = await activeVisionIds();
    for (final id in ids) {
      final m = ModelCatalog.byId(id);
      if (m != null && m.isVision && await isInstalled(m)) return m;
    }
    // fallback to legacy single key
    final legacyId = await activeVisionId();
    if (legacyId != null) {
      final m = ModelCatalog.byId(legacyId);
      if (m != null && m.isVision && await isInstalled(m)) return m;
    }
    return null;
  }

  /// The active embedding model, or null when none is installed/selected.
  ///
  /// Deliberately no fallback: Memory search must be *off* rather than
  /// silently producing hash-token garbage when the encoder is absent.
  Future<LocalModel?> activeEmbedding() async {
    final ids = await activeEmbeddingIds();
    for (final id in ids) {
      final m = ModelCatalog.byId(id);
      if (m != null && m.isEmbedding && await isInstalled(m)) return m;
    }
    // fallback to legacy single key
    final legacyId = await activeEmbeddingId();
    if (legacyId != null) {
      final m = ModelCatalog.byId(legacyId);
      if (m != null && m.isEmbedding && await isInstalled(m)) return m;
    }
    return null;
  }
}

// =============================================================== file helpers

Future<int> _lengthOrZero(File f) async {
  if (!await f.exists()) return 0;
  return await f.length();
}

Future<void> _deleteQuietly(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } catch (e) {
    // Best-effort by name, but never silent: a `.part` that cannot be deleted
    // because the volume is full is the one case where "clean restart" silently
    // becomes "resume a corrupt file", and the user has no other way to see it.
    Log.w('ModelManager: could not delete ${f.path}: $e');
  }
}

Future<_PartMeta?> _readMeta(File meta) async {
  try {
    if (!await meta.exists()) return null;
    return _PartMeta.fromJson(await meta.readAsString());
  } catch (e) {
    Log.w('ModelManager: unreadable validator sidecar ${meta.path}: $e');
    return null;
  }
}

Future<void> _writeMeta(File meta, _PartMeta data) async {
  try {
    await meta.writeAsString(jsonEncode(data.toJson()), flush: true);
  } catch (e) {
    // Losing the sidecar only costs a clean restart on the next attempt — but
    // it is worth saying so, because the resume path looks inexplicable without
    // it.
    Log.w(
      'ModelManager: could not persist validators to ${meta.path}; the next '
      'attempt will restart the download instead of resuming: $e',
    );
  }
}

/// Parses the Accept-Ranges header into a tri-state: true/false/null.
///
/// `null` means the server omitted the header entirely (common on a 206
/// response where it is redundant). We must not treat that as "no ranges":
/// a 206 body is itself proof that ranges work, so null means "unknown" and
/// resume planning treats it as permissive.
bool? _acceptsRanges(String? header) {
  if (header == null) return null;
  final lower = header.toLowerCase();
  if (lower.contains('bytes')) return true;
  if (lower.contains('none')) return false;
  return null;
}

/// Parses the start offset from a `Content-Range` header
/// (`bytes 100-999/1000`), or null when absent/unparseable.
int? _parseContentRangeStart(String? header) {
  if (header == null) return null;
  final match = RegExp(r'bytes\s+(\d+)-').firstMatch(header);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}
