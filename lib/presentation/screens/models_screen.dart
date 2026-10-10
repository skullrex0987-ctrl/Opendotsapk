/// Models screen — pick what you want, then download it in-app.
///
/// Nothing ships inside the APK; every model is streamed from Hugging Face
/// into app-private storage with live progress. The list is grouped by role
/// because the three roles are genuinely different:
///
///   Chat       one GGUF brain. You need exactly one.
///   Vision     a GGUF + its mmproj projector, loaded on top of the brain.
///              Only Moondream2 is offered because it is the only small GGUF
///              whose projector llama.cpp can actually serve on-device.
///   Embeddings an ONNX encoder + vocab.txt that backs Memory search.
///              Optional, but Memory silently does nothing without it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/local_model.dart';
import '../../data/services/model_manager.dart';

class ModelsScreen extends ConsumerStatefulWidget {
  const ModelsScreen({super.key});

  @override
  ConsumerState<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends ConsumerState<ModelsScreen> {
  final ModelManager _manager = ModelManager.getInstance();

  /// modelId -> latest download progress, so rows survive rebuilds.
  final Map<String, double> _progress = {};
  final Set<String> _busy = {};

  String? _activeLlm;
  String? _activeVision;
  String? _activeEmbedding;

  int _storageBytes = 0;

  @override
  void initState() {
    super.initState();
    _loadSelection();
    _loadStorage();
  }

  Future<void> _loadStorage() async {
    final bytes = await _manager.installedBytes();
    if (!mounted) return;
    setState(() => _storageBytes = bytes);
  }

  static String _fmtBytes(int b) {
    if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
    if (b >= 1 << 20) return '${(b / (1 << 20)).round()} MB';
    if (b <= 0) return '0 MB';
    return '${(b / (1 << 10)).round()} KB';
  }

  Future<void> _loadSelection() async {
    // `Future.wait` returns the list of results, not a single String?, so the
    // await has to be on the awaited list itself.
    final List<String?> ids = await Future.wait<String?>([
      _manager.activeLlmId(),
      _manager.activeVisionId(),
      _manager.activeEmbeddingId(),
    ]);
    if (!mounted) return;
    setState(() {
      _activeLlm = ids[0];
      _activeVision = ids[1];
      _activeEmbedding = ids[2];
    });
  }

  String? _selectedFor(ModelKind kind) {
    switch (kind) {
      case ModelKind.llm:
        return _activeLlm;
      case ModelKind.vision:
        return _activeVision;
      case ModelKind.embedding:
        return _activeEmbedding;
    }
  }

  Future<void> _select(LocalModel m, bool installed) async {
    switch (m.kind) {
      case ModelKind.llm:
        await _manager.setActiveLlmId(installed ? m.id : null);
        break;
      case ModelKind.vision:
        await _manager.setActiveVisionId(installed ? m.id : null);
        break;
      case ModelKind.embedding:
        await _manager.setActiveEmbeddingId(installed ? m.id : null);
        break;
    }
    await _loadSelection();
  }

  Future<void> _download(LocalModel m) async {
    if (_busy.contains(m.id)) return;
    setState(() => _busy.add(m.id));

    final completer = Completer<void>();
    late StreamSubscription sub;

    void finish() {
      if (!completer.isCompleted) completer.complete();
      sub.cancel();
      if (mounted) {
        setState(() {
          _busy.remove(m.id);
          _progress.remove(m.id);
        });
      }
    }

    sub = _manager.download(m).listen(
      (p) {
        if (!mounted) return;
        setState(() => _progress[m.id] = p.fraction ?? 0.0);
        if (p.error != null) {
          finish();
          _toast('${m.displayName}: ${p.error}');
          return;
        }
        if (p.done) {
          finish();
          // Selecting straight after a successful download saves a tap.
          _select(m, true);
          _loadStorage();
          _toast('${m.displayName} installed');
        }
      },
      onError: (Object e) {
        finish();
        _toast('Download failed: $e');
      },
      onDone: finish,
      cancelOnError: true,
    );

    await completer.future;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _SectionHeader(
            title: 'Chat model',
            subtitle: 'The brain. Pick one — download it, then it is selected '
                'automatically. Needs ~600 MB RAM.',
          ),
          ...ModelCatalog.llms.map(
            (m) => _row(m, selectedId: _activeLlm),
          ),
          const Divider(height: 32),
          const _SectionHeader(
            title: 'Vision model',
            subtitle: 'Lets the agent read pictures. Loaded on top of the chat '
                'model. Moondream2 is the only small GGUF llama.cpp can serve '
                'on-device; Needle is excluded because it needs the Cactus '
                'native runtime, not llama.cpp.',
          ),
          ...ModelCatalog.visionModels.map(
            (m) => _row(m, selectedId: _activeVision, usable: ModelCatalog.isUsable(m)),
          ),
          const Divider(height: 32),
          const _SectionHeader(
            title: 'Embeddings',
            subtitle: 'Powers Memory search. Without it, past conversations '
                'are stored but never retrieved.',
          ),
          ...ModelCatalog.embeddingModels.map(
            (m) => _row(m, selectedId: _activeEmbedding),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Storage used by downloaded models: ${_fmtBytes(_storageBytes)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(LocalModel m, {required String? selectedId, bool usable = true}) {
    return FutureBuilder<bool>(
      future: _manager.isInstalled(m),
      builder: (context, snap) {
        final installed = snap.data ?? false;
        final selected = installed && selectedId == m.id;
        final busy = _busy.contains(m.id);
        final progress = _progress[m.id];
        final active = usable && installed;

        return ListTile(
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : (usable ? Icons.radio_button_unchecked : Icons.block),
            color: selected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(m.displayName),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(m.description, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 2),
              Text(
                '${m.sizeLabel}  ·  ${m.ramHint}  ·  ctx ${m.contextSize}'
                '${installed ? '  ·  downloaded' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              if (busy && progress != null) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress),
              ],
            ],
          ),
          isThreeLine: true,
          trailing: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : installed
                  ? IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await _manager.delete(m);
                        await _loadSelection();
                        await _loadStorage();
                        if (mounted) {
                          setState(() {});
                          _toast('${m.displayName} deleted');
                        }
                      },
                    )
                  : IconButton(
                      tooltip: usable ? 'Download' : 'Not supported yet',
                      icon: Icon(
                        Icons.cloud_download_outlined,
                        color: usable ? null : Colors.grey,
                      ),
                      onPressed: usable ? () => _download(m) : null,
                    ),
          onTap: usable
              ? () async {
            if (!installed) {
              await _download(m);
            } else {
              await _select(m, true);
              if (mounted) setState(() {});
            }
          }
              : null,
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}