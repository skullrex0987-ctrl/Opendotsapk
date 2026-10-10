/// Downloads, stores, deletes and selects the on-device GGUF models.
///
/// Models live under `<app documents>/models/`. Nothing is bundled in the APK;
/// the user picks a model in Settings and the app streams it from Hugging Face
/// with live progress. Safe to cancel mid-download (partial file is removed).
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../domain/models/local_model.dart';

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

class ModelManager {
  static ModelManager? _instance;
  ModelManager._();

  static ModelManager getInstance() => _instance ??= ModelManager._();

  static const Duration _connectTimeout = Duration(seconds: 30);

  /// Directory that holds all downloaded models.
  Future<Directory> modelsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, AppConstants.modelsDirName));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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
  Future<bool> isInstalled(LocalModel m) async {
    final floors = _floorsFor(m);

    for (final f in m.files) {
      final file = File(await pathForFile(f.name));
      if (!await file.exists()) return false;
      if (await file.length() < (floors[f.name] ?? m.minBytes)) return false;
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

  /// Delete a model's files (main + projector).
  Future<void> delete(LocalModel m) async {
    for (final f in m.files) {
      final file = File(await pathForFile(f.name));
      if (await file.exists()) {
        await file.delete();
      }
    }
    // Clear the selection if the deleted model was active.
    if (await activeLlmId() == m.id) await setActiveLlmId(null);
    if (await activeVisionId() == m.id) await setActiveVisionId(null);
    if (await activeEmbeddingId() == m.id) await setActiveEmbeddingId(null);
  }

  /// Download a model, emitting progress until complete.
  ///
  /// A `.part` file is used and renamed on success, so an interrupted download
  /// never leaves a half file that [isInstalled] would treat as valid.
  Stream<DownloadProgress> download(LocalModel m) async* {
    final dir = await modelsDir();
    final totalBytes = m.approxBytes;
    final floors = _floorsFor(m);

    for (final f in m.files) {
      final target = File(p.join(dir.path, f.name));
      final partFile = File('${target.path}.part');
      final floor = floors[f.name] ?? m.minBytes;

      if (await target.exists() && await target.length() >= floor) {
        continue; // already have this file
      }

      final client = http.Client();
      IOSink? sink;
      var received = 0;

      try {
        final request = http.Request('GET', Uri.parse(f.url));
        final response = await client.send(request).timeout(_connectTimeout);

        if (response.statusCode != 200) {
          yield DownloadProgress(
            modelId: m.id,
            received: 0,
            total: totalBytes,
            currentFile: f.name,
            error: 'Server returned HTTP ${response.statusCode}',
          );
          client.close();
          return;
        }

        final contentLength = response.contentLength ?? 0;
        sink = partFile.openWrite();

        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          yield DownloadProgress(
            modelId: m.id,
            received: received,
            total: contentLength > 0 ? contentLength : totalBytes,
            currentFile: f.name,
          );
        }

        await sink.flush();
        await sink.close();
        sink = null;
        client.close();

        // Promote the completed file.
        if (await target.exists()) await target.delete();
        await partFile.rename(target.path);
      } catch (e) {
        try {
          await sink?.close();
        } catch (_) {}
        client.close();
        if (await partFile.exists()) {
          await partFile.delete();
        }
        yield DownloadProgress(
          modelId: m.id,
          received: received,
          total: totalBytes,
          currentFile: f.name,
          error: 'Download failed: $e',
        );
        return;
      }
    }

    yield DownloadProgress(
      modelId: m.id,
      received: totalBytes,
      total: totalBytes,
      currentFile: m.fileName,
      done: true,
    );
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

  /// The active chat model, falling back to the default when unset/missing.
  Future<LocalModel> activeLlm() async {
    final id = await activeLlmId();
    final m = ModelCatalog.byId(id);
    if (m != null && m.kind == ModelKind.llm && await isInstalled(m)) return m;
    return ModelCatalog.defaultLlm;
  }

  /// The active vision model, or null when none is installed/selected.
  Future<LocalModel?> activeVision() async {
    final id = await activeVisionId();
    final m = ModelCatalog.byId(id);
    if (m != null && m.isVision && await isInstalled(m)) return m;
    return null;
  }

  /// The active embedding model, or null when none is installed/selected.
  ///
  /// Deliberately no fallback: Memory search must be *off* rather than
  /// silently producing hash-token garbage when the encoder is absent.
  Future<LocalModel?> activeEmbedding() async {
    final id = await activeEmbeddingId();
    final m = ModelCatalog.byId(id);
    if (m != null && m.isEmbedding && await isInstalled(m)) return m;
    return null;
  }
}
