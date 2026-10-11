/// Models screen — pick what you want, then download it in-app.
///
/// Nothing ships inside the APK; every model is streamed from Hugging Face
/// into app-private storage with live progress. The list is grouped by role
/// because the three roles are genuinely different:
///
///   Chat       one GGUF brain. You need exactly one.
///   Vision     a vision-capable GGUF + its mmproj. Qwen3.5 carries its own
///              ViT, so a single download both chats and sees. Moondream2
///              stays listed but disabled: this build of llama.cpp has no
///              encoder for its projector, so it can never load.
///   Embeddings an ONNX encoder + vocab.txt that backs Memory search.
///              Optional, but Memory silently does nothing without it.
///
/// The presentation problem this screen has to solve is that a download is a
/// long, silent wait on a phone. A row that only says "downloading" leaves the
/// user guessing whether it stalled; every row therefore carries its own byte
/// counts, a determinate bar and an explicit percentage, so "how long is left"
/// is answerable without leaving the screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/model_manager.dart';
import '../../domain/models/local_model.dart';
import '../widgets/screen_empty_state.dart';

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

  /// True once at least one model has been seen installed on disk.
  ///
  /// Drives the first-run card. It cannot be derived from [_activeLlm]: a user
  /// who downloads a model and never selects it has storage on disk but a null
  /// selection, and would be told they have nothing.
  bool _anythingInstalled = false;

  @override
  void initState() {
    super.initState();
    _loadSelection();
    _loadStorage();
  }

  Future<void> _loadStorage() async {
    final bytes = await _manager.installedBytes();
    // Anything but a zero-byte models directory means at least one file landed
    // there, which is the signal the first-run card needs. Probing every
    // catalogue entry with isInstalled() would cost six directory stats and
    // promise nothing extra.
    final present = bytes > 0;
    if (!mounted) return;
    setState(() {
      _storageBytes = bytes;
      if (present) _anythingInstalled = true;
    });
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

  /// Write [m] into the selection slot its **section** belongs to.
  ///
  /// Dispatching on `m.kind` sends Qwen3.5 to `activeVisionId` no matter which
  /// section it was tapped in, because it is registered as
  /// [ModelKind.vision] while also being a perfectly good chat model. Tapping
  /// it under "Chat model" therefore left `activeLlmId` on a different model
  /// and Load bound the wrong one. The section is the authority.
  Future<void> _select(LocalModel m, bool installed, ModelKind section) async {
    switch (section) {
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

  Future<void> _download(LocalModel m, ModelKind section) async {
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

    sub = _manager
        .download(m)
        .listen(
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
              _select(m, true, section);
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _storageCard(theme, scheme),
          if (!_anythingInstalled) ...[
            const SizedBox(height: 4),
            _firstRunCard(),
          ],
          const SizedBox(height: 8),
          const _SectionHeader(
            title: 'Chat model',
            subtitle:
                'The brain. Pick one — download it, then it is selected '
                'automatically. Needs ~600 MB RAM.',
          ),
          ...ModelCatalog.llms.map(
            (m) => _row(m, selectedId: _activeLlm, section: ModelKind.llm),
          ),
          const Divider(height: 32),
          const _SectionHeader(
            title: 'Vision model',
            subtitle:
                'Lets the agent read pictures. Qwen3.5 has vision built '
                'in, so one download is enough — it chats and sees. Any entry '
                'greyed out is not supported by this build\'s llama.cpp.',
          ),
          ...ModelCatalog.visionModels.map(
            (m) => _row(
              m,
              selectedId: _activeVision,
              section: ModelKind.vision,
              usable: ModelCatalog.isUsable(m),
            ),
          ),
          const Divider(height: 32),
          const _SectionHeader(
            title: 'Embeddings',
            subtitle:
                'Powers Memory search. Without it, past conversations '
                'are stored but never retrieved.',
          ),
          ...ModelCatalog.embeddingModels.map(
            (m) => _row(
              m,
              selectedId: _activeEmbedding,
              section: ModelKind.embedding,
            ),
          ),
        ],
      ),
    );
  }

  /// Storage used, plus the fact that models live on the device.
  ///
  /// This is the first thing on the screen on purpose: "how much space does
  /// this app hold" is the question people have here after a few hundred
  /// megabytes has appeared, and the answer was previously at the very bottom
  /// of a scrolling list, after every catalogue entry.
  Widget _storageCard(ThemeData theme, ColorScheme scheme) {
    final used = _storageBytes > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _StorageDial(used: used),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      used
                          ? '${_fmtBytes(_storageBytes)} of models'
                          : 'No models yet',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Models are stored on this device and never leave it. '
                      'They keep working with no network at all.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// First run: say what is missing and give the one action that fixes it.
  ///
  /// The button calls the same [_download] the row does, with the same
  /// section, so the fast path and the full path cannot drift apart — a
  /// separate bespoke download here is how a "recommended" entry ends up not
  /// selecting the model it just fetched.
  Widget _firstRunCard() {
    final recommended = ModelCatalog.defaultLlm;

    return ScreenEmptyState(
      icon: Icons.download_for_offline_outlined,
      title: 'Download a model to start chatting',
      message:
          'Nothing is bundled with the app, so there is no assistant until a '
          'model is on this device. ${recommended.displayName} '
          '(${recommended.sizeLabel}) is the best balance for most phones.',
      actionLabel: 'Download ${recommended.displayName}',
      actionIcon: Icons.download,
      onAction: () => _download(recommended, ModelKind.llm),
      compact: true,
    );
  }

  Widget _row(
    LocalModel m, {
    required String? selectedId,
    required ModelKind section,
    bool usable = true,
  }) {
    return FutureBuilder<bool>(
      future: _manager.isInstalled(m),
      builder: (context, snap) {
        final installed = snap.data ?? false;
        final selected = installed && selectedId == m.id;
        final busy = _busy.contains(m.id);
        final progress = _progress[m.id];

        if (snap.connectionState == ConnectionState.waiting) {
          return _ModelRowShell(child: const _RowSkeleton());
        }

        return _ModelRowShell(
          child: _ModelRow(
            model: m,
            installed: installed,
            selected: selected,
            usable: usable,
            busy: busy,
            progress: progress,
            onDelete: () async {
              await _manager.delete(m);
              await _loadSelection();
              await _loadStorage();
              if (mounted) {
                setState(() {});
                _toast('${m.displayName} deleted');
              }
            },
            onDownload: () => _download(m, section),
            onSelect: () async {
              if (!installed) {
                await _download(m, section);
              } else {
                await _select(m, true, section);
                if (mounted) setState(() {});
              }
            },
          ),
        );
      },
    );
  }
}

/// A circular storage readout.
///
/// A dial rather than a bare number because the useful comparison is "how much
/// of my phone is this", and a bar communicates that without a second label.
class _StorageDial extends StatelessWidget {
  const _StorageDial({required this.used});

  /// Whether anything is installed; drives the icon and its tint.
  final bool used;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = used ? AppColors.accent : scheme.onSurfaceVariant;

    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(
        used ? Icons.sd_storage : Icons.sd_storage_outlined,
        size: 22,
        color: tint,
      ),
    );
  }
}

/// Padding + tap target shared by every row, so rows line up whether they are
/// showing real content or the loading placeholder.
class _ModelRowShell extends StatelessWidget {
  const _ModelRowShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: child,
    );
  }
}

/// Placeholder shown while [ModelManager.isInstalled] stats the files.
///
/// A shimmer was the obvious choice and is the wrong one here: the check is a
/// handful of `File.length()` calls that resolve in well under a frame, so a
/// 400 ms shimmer would outlive the answer and read as a stutter.
class _RowSkeleton extends StatelessWidget {
  const _RowSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bar = scheme.surfaceContainerHighest;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: bar, shape: BoxShape.circle),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 12, color: bar),
                  const SizedBox(height: 8),
                  Container(height: 10, width: 140, color: bar),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One model row: identity, state, and the controls that change it.
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.installed,
    required this.selected,
    required this.usable,
    required this.busy,
    required this.progress,
    required this.onDelete,
    required this.onDownload,
    required this.onSelect,
  });

  final LocalModel model;
  final bool installed;
  final bool selected;
  final bool usable;
  final bool busy;
  final double? progress;
  final VoidCallback onDelete;
  final VoidCallback onDownload;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        side: BorderSide(
          color: selected
              ? scheme.primary.withValues(alpha: 0.55)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        onTap: usable ? onSelect : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _RoleIcon(
                  kind: model.kind,
                  usable: usable,
                  selected: selected,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.displayName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: usable ? null : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(model.description, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    _MetaLine(model: model),
                    const SizedBox(height: 8),
                    _StateBadge(
                      installed: installed,
                      selected: selected,
                      usable: usable,
                      busy: busy,
                    ),
                    if (model.unsupportedReason != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              model.unsupportedReason!,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (busy && progress != null) ...[
                      const SizedBox(height: 10),
                      _DownloadProgress(
                        fraction: progress!,
                        sizeLabel: model.sizeLabel,
                      ),
                    ],
                  ],
                ),
              ),
              _RowActions(
                busy: busy,
                installed: installed,
                usable: usable,
                onDelete: onDelete,
                onDownload: onDownload,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Role glyph: the three roles are genuinely different, so they get different
/// shapes rather than three labels in the same circle.
class _RoleIcon extends StatelessWidget {
  const _RoleIcon({
    required this.kind,
    required this.usable,
    required this.selected,
  });

  final ModelKind kind;
  final bool usable;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = !usable
        ? scheme.onSurfaceVariant
        : selected
        ? scheme.primary
        : kind == ModelKind.embedding
        ? AppColors.accent
        : AppColors.brand;

    final icon = switch (kind) {
      ModelKind.llm => Icons.psychology_outlined,
      ModelKind.vision => Icons.visibility_outlined,
      // Icons.embed_outlined does not exist in the Material icon set (only
      // embed/embed_rounded/embed_sharp do), which the analyzer does not catch
      // but the kernel snapshot does. dns_outlined reads as "stored vectors"
      // and is already used elsewhere in the app.
      ModelKind.embedding => Icons.dns_outlined,
    };

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(usable ? icon : Icons.block, size: 19, color: tint),
    );
  }
}

/// Size / RAM / context, plus the role spelled out.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.model});

  final LocalModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final parts = <String>[
      if (model.ramHint.isNotEmpty) model.ramHint,
      'ctx ${model.contextSize}',
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          model.sizeLabel,
          style: theme.textTheme.labelMedium?.copyWith(color: muted),
        ),
        for (final p in parts)
          Text(p, style: theme.textTheme.labelMedium?.copyWith(color: muted)),
      ],
    );
  }
}

/// The explicit state word. Colour alone would fail here: "downloaded" and
/// "not downloaded" differ by the same few pixels, and this list is scanned in
/// bad light on a phone held at arm's length.
class _StateBadge extends StatelessWidget {
  const _StateBadge({
    required this.installed,
    required this.selected,
    required this.usable,
    required this.busy,
  });

  final bool installed;
  final bool selected;
  final bool usable;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    late final String label;
    late final Color tint;
    late final IconData icon;

    if (!usable) {
      label = 'Unavailable on this build';
      tint = theme.colorScheme.onSurfaceVariant;
      icon = Icons.block;
    } else if (busy) {
      label = 'Downloading';
      tint = AppColors.accent;
      icon = Icons.downloading;
    } else if (selected) {
      label = 'Selected';
      tint = AppColors.success;
      icon = Icons.check_circle;
    } else if (installed) {
      label = 'Downloaded';
      tint = AppColors.success;
      icon = Icons.check_circle_outline;
    } else {
      label = 'Not downloaded';
      tint = theme.colorScheme.onSurfaceVariant;
      icon = Icons.cloud_download_outlined;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: tint),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: tint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Determinate bar plus the two numbers that make "how long" answerable.
///
/// A bar alone is a progress bar; a bar with a percentage and a byte count is
/// a progress bar *and* an ETA. Users comparing a 400 MB model against a 1.1 GB
/// one need the total to judge whether to switch, not just the rate.
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.fraction, required this.sizeLabel});

  final double fraction;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = (fraction.clamp(0.0, 1.0) * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.accent),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '$pct%',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Text('of $sizeLabel', style: theme.textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}

/// Trailing controls: busy spinner, delete, or download.
///
/// Kept as a separate widget so the button order and enablement rules live in
/// one place — they used to be a nested ternary inside the row, where the
/// `busy` branch shadowed the delete button and made an in-flight model
/// impossible to remove.
class _RowActions extends StatelessWidget {
  const _RowActions({
    required this.busy,
    required this.installed,
    required this.usable,
    required this.onDelete,
    required this.onDownload,
  });

  final bool busy;
  final bool installed;
  final bool usable;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }

    if (installed) {
      return IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      );
    }

    return IconButton(
      tooltip: usable ? 'Download' : 'Not supported yet',
      icon: Icon(
        Icons.cloud_download_outlined,
        color: usable ? null : Theme.of(context).disabledColor,
      ),
      onPressed: usable ? onDownload : null,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 3),
          Text(subtitle, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
