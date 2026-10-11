/// Performance and device diagnostics.
///
/// Why this screen exists rather than a silent "use the GPU" flag: on a large
/// class of phones the GPU is genuinely *slower* than the CPU for token
/// generation. Generation is memory-bandwidth-bound, and a midrange mobile GPU
/// with a narrow memory bus does not beat well-vectorised NEON kernels. A user
/// whose phone falls into that class should be able to see it and switch back,
/// rather than concluding the app is slow.
///
/// So the screen does three things: it reports what the device actually is, it
/// lets the backend be chosen, and it measures both so the choice can be based
/// on the user's own hardware instead of on a guess made at build time.
///
/// Every control is explained in one line. A thread count is not
/// self-explanatory, and "I moved this slider and now generation is slower" is
/// a support question the explanation prevents.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../data/services/gpu_service.dart';
import '../../data/services/llm_service.dart';
import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';

class PerformanceScreen extends ConsumerStatefulWidget {
  const PerformanceScreen({super.key});

  @override
  ConsumerState<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends ConsumerState<PerformanceScreen> {
  GpuCapability? _gpu;
  bool _loadingDevice = true;

  bool _benchmarking = false;
  String? _benchmarkResult;
  double _lastTokensPerSecond = 0.0;

  /// Throughput from the last CPU run of the auto-benchmark, kept separately so
  /// the comparison bars have both halves. Null until a comparison has run.
  double? _cpuTokensPerSecond;

  /// Throughput from the last GPU run of the auto-benchmark.
  double? _gpuTokensPerSecond;

  @override
  void initState() {
    super.initState();
    _loadDevice();
  }

  Future<void> _loadDevice() async {
    final gpu = await GpuService.detect();
    if (!mounted) return;
    setState(() {
      _gpu = gpu;
      _loadingDevice = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final llm = ref.read(llmServiceProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Performance')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _deviceCard(llm),
          const SizedBox(height: 16),
          _backendCard(settings, llm),
          const SizedBox(height: 16),
          _threadsCard(settings),
          const SizedBox(height: 16),
          _benchmarkCard(llm),
          const SizedBox(height: 16),
          _npuCard(),
        ],
      ),
    );
  }

  Widget _deviceCard(LlmService llm) {
    if (_loadingDevice) {
      return const ScreenLoadingState(label: 'Reading device information…');
    }

    final gpu = _gpu ?? GpuCapability.unknown;
    final ram = gpu.totalRamMb > 0
        ? '${(gpu.totalRamMb / 1024).toStringAsFixed(1)} GB'
        : 'unknown';
    final backend = llm.activeBackend ?? 'none';
    final backendLabel = switch (backend) {
      'vulkan' => 'Vulkan (GPU)',
      'cpu' => 'CPU only',
      _ => 'Unknown',
    };

    return _Card(
      title: 'This device',
      subtitle: gpu.summary,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _Stat(label: 'System on chip', value: gpu.socModel),
          _Stat(label: 'Hardware', value: gpu.hardware),
          _Stat(label: 'Memory', value: ram, numeric: true),
          _Stat(label: 'GPU', value: gpu.gpuLabel),
          _Stat(
            label: 'Backend',
            value: backendLabel,
            numeric: backend != 'none',
          ),
          _Stat(label: 'Layers offloaded', value: '${llm.gpuLayers}', numeric: true),
          _Stat(label: 'CPU threads', value: '${llm.threads}', numeric: true),
        ],
      ),
    );
  }

  Widget _backendCard(Map<String, dynamic> settings, LlmService llm) {
    final mode = '${settings['gpu_offload'] ?? 'auto'}';

    return _Card(
      title: 'Compute backend',
      subtitle: _modeExplanation(mode),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'auto', label: Text('Auto')),
              ButtonSegment(value: 'gpu', label: Text('GPU')),
              ButtonSegment(value: 'cpu', label: Text('CPU')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => _setMode(s.first),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Changing this reloads the model — takes a few seconds.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _modeExplanation(String mode) {
    switch (mode) {
      case 'gpu':
        return 'Always attempt GPU offload. If the driver refuses, llama.cpp '
            'falls back to the CPU automatically.';
      case 'cpu':
        return 'Never use the GPU. Try this if responses feel slower than '
            'expected — on many midrange GPUs the CPU is faster.';
      default:
        return 'Decide from the chipset: GPU on capable hardware, CPU on '
            'devices where the GPU usually loses.';
    }
  }

  Widget _threadsCard(Map<String, dynamic> settings) {
    final current = int.tryParse('${settings['cpu_threads']}') ?? 4;
    final theme = Theme.of(context);

    return _Card(
      title: 'CPU threads',
      subtitle:
          'How many cores are used for inference. More threads speed up '
          'prompt processing but can slow down token generation, which is '
          'memory-bandwidth-bound. $current is a safe starting point.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Threads', style: theme.textTheme.labelMedium),
              const Spacer(),
              // The number is the setting; it is the thing being changed, so it
              // gets the accent rather than a grey label.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                ),
                child: Text(
                  '$current',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
          Slider(
            value: current.toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            label: '$current',
            onChanged: (v) {
              ref
                  .read(settingsProvider.notifier)
                  .updateSetting('cpu_threads', v.toInt());
              setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Future<void> _setMode(String mode) async {
    final settings = ref.read(settingsProvider);
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('gpu_offload', mode);
    if (!mounted) return;

    // Also save thread count when reloading
    final currentThreads = int.tryParse('${settings['cpu_threads']}') ?? 4;
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('cpu_threads', currentThreads);

    // The backend is fixed at model-load time, so the change only takes effect
    // after a reload. Offer it rather than silently doing nothing.
    final reload = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reload the model?'),
        content: const Text(
          'The compute backend is chosen when the model loads, so the new '
          'setting applies after a reload.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reload now'),
          ),
        ],
      ),
    );

    if (reload == true && mounted) {
      final llm = ref.read(llmServiceProvider);
      final path = llm.modelPath;
      if (path == null) return;

      final ctx = context;
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
      final ok = await llm.loadModel(path, gpuLayers: _layersFor(mode));
      if (ctx.mounted) Navigator.of(ctx).pop();
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(ok ? 'Model reloaded.' : 'Reload failed.')),
        );
      }
      setState(() {});
    }
  }

  int _layersFor(String mode) {
    switch (mode) {
      case 'gpu':
        return 99;
      case 'cpu':
        return 0;
      default:
        return _gpu?.recommendedGpuLayers ?? 0;
    }
  }

  Widget _benchmarkCard(LlmService llm) {
    final cpu = _cpuTokensPerSecond;
    final gpu = _gpuTokensPerSecond;

    return _Card(
      title: 'Benchmark',
      subtitle:
          'Generates a short reply and measures throughput. Run it on the '
          'CPU and on the GPU to see which is genuinely faster on your phone.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FilledButton.icon(
            onPressed: (_benchmarking || !llm.isLoaded) ? null : _benchmark,
            icon: _benchmarking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed, size: 18),
            label: Text(_benchmarking ? 'Measuring…' : 'Run benchmark'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: (_benchmarking || !llm.isLoaded) ? null : _autoBenchmark,
            icon: _benchmarking
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome, size: 18),
            label: const Text('Auto-optimize (test CPU + GPU)'),
          ),
          if (!llm.isLoaded) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 14,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Load a model first.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (_benchmarkResult != null) ...[
            const SizedBox(height: 16),
            // The comparison is the point of this card, so it gets the
            // animation: two bars growing to the same scale is the fastest way
            // to communicate "these are close" or "this one wins".
            if (cpu != null && gpu != null)
              _ComparisonBars(cpu: cpu, gpu: gpu),
            if (cpu == null && gpu == null && _lastTokensPerSecond > 0)
              _SingleBar(
                label: 'Last measurement',
                value: _lastTokensPerSecond,
              ),
            if (cpu != null || gpu != null) ...[
              const SizedBox(height: 10),
              _Verdict(cpu: cpu, gpu: gpu),
            ],
            const SizedBox(height: 12),
            Text(
              _benchmarkResult!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _benchmark() async {
    setState(() {
      _benchmarking = true;
      _benchmarkResult = null;
    });

    final llm = ref.read(llmServiceProvider);
    final sw = Stopwatch()..start();
    var tokens = 0;

    try {
      await for (final _ in llm.generateStream(
        prompt: 'Count from one to twenty in words, separated by spaces.',
        maxTokens: 96,
      )) {
        tokens++;
        // Abort as soon as there is a usable sample; no need to finish.
        if (tokens >= 64) break;
      }
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _benchmarking = false;
        _benchmarkResult = 'Benchmark failed: $e';
      });
      return;
    }

    sw.stop();
    if (!mounted) return;

    final seconds = sw.elapsedMilliseconds / 1000.0;
    final tps = seconds > 0 ? tokens / seconds : 0.0;

    setState(() {
      _benchmarking = false;
      _lastTokensPerSecond = tps;
      final backend = llm.gpuLayers > 0 ? 'GPU' : 'CPU';
      _benchmarkResult =
          '$tokens tokens in ${seconds.toStringAsFixed(1)}s\n'
          '${tps.toStringAsFixed(1)} tokens/sec on $backend '
          '(${llm.gpuLayers > 0 ? '${llm.gpuLayers} layers offloaded' : 'all layers on the CPU'})';
    });
  }

  /// Run benchmarks on both CPU and GPU, then auto-select the faster backend.
  Future<void> _autoBenchmark() async {
    setState(() {
      _benchmarking = true;
      _benchmarkResult = 'Testing CPU…';
    });

    final llm = ref.read(llmServiceProvider);

    // Test CPU first
    await _applyMode('cpu');
    final cpuTps = await _measureTps(llm);

    if (!mounted) return;
    setState(() {
      _benchmarkResult =
          'CPU: ${cpuTps.toStringAsFixed(1)} tok/s. Testing GPU…';
    });

    // Test GPU
    await _applyMode('gpu');
    final gpuTps = await _measureTps(llm);

    if (!mounted) return;

    // Select the faster backend
    final isGpuFaster = gpuTps > cpuTps;
    await _applyMode(isGpuFaster ? 'gpu' : 'cpu');

    setState(() {
      _benchmarking = false;
      _cpuTokensPerSecond = cpuTps;
      _gpuTokensPerSecond = gpuTps;
      _benchmarkResult =
          'CPU: ${cpuTps.toStringAsFixed(1)} tok/s\n'
          'GPU: ${gpuTps.toStringAsFixed(1)} tok/s\n'
          '→ Auto-selected ${isGpuFaster ? 'GPU' : 'CPU'} (${((isGpuFaster ? gpuTps : cpuTps) / (isGpuFaster ? cpuTps : gpuTps) * 100 - 100).toStringAsFixed(0)}% faster)';
    });
  }

  Future<double> _measureTps(LlmService llm) async {
    final sw = Stopwatch()..start();
    var tokens = 0;
    try {
      await for (final _ in llm.generateStream(
        prompt: 'Count from one to twenty in words, separated by spaces.',
        maxTokens: 96,
      )) {
        tokens++;
        if (tokens >= 64) break;
      }
    } catch (e) {
      return 0.0;
    }
    sw.stop();
    final seconds = sw.elapsedMilliseconds / 1000.0;
    return seconds > 0 ? tokens / seconds : 0.0;
  }

  Future<void> _applyMode(String mode) async {
    await ref
        .read(settingsProvider.notifier)
        .updateSetting('gpu_offload', mode);
    // Reload model with new settings
    final llm = ref.read(llmServiceProvider);
    final path = llm.modelPath;
    if (path != null) {
      final layers = mode == 'cpu' ? 0 : 99;
      await llm.loadModel(path, gpuLayers: layers);
    }
  }

  Widget _npuCard() {
    final gpu = _gpu ?? GpuCapability.unknown;

    return _Card(
      title: 'Neural accelerator',
      subtitle: gpu.npuLabel,
      trailing: const _Tag(
        label: 'not used',
        color: AppColors.warning,
        icon: Icons.block,
      ),
      child: Text(
        'Every phone NPU needs its own vendor runtime — Qualcomm QNN, '
        'MediaTek NeuroPilot, Samsung ENN, Google Edge TPU — with '
        'different SDKs and licences and no common build target. There is '
        'no portable NPU backend for llama.cpp, so claiming NPU '
        'acceleration here would be a lie. This app uses the GPU '
        '(Vulkan) or the CPU.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

/// Titled card used for every block on this screen.
///
/// The screen was five unlabelled [Card]s stacked with a bold word as a title;
/// giving each one a real header, an explanation line and consistent padding
/// is what makes it read as one settings page rather than a debug dump.
class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// One value from the device probe.
///
/// Numbers get the accent colour on purpose: "4.8 GB" and "Snapdragon 8 Gen 1"
/// are different kinds of fact, and colour is the cheapest way to say which is
/// the measurement.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    this.numeric = false,
  });

  final String label;
  final String value;
  final bool numeric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: 148,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 3),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: numeric ? AppColors.accent : null,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small pill for a state that needs words ("not used", "active").
class _Tag extends StatelessWidget {
  const _Tag({
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// CPU vs GPU as two bars on a shared scale.
///
/// Both bars are drawn against the same maximum, because two independently
/// scaled bars would make a 6 vs 7 tok/s result look like a landslide. The
/// animation runs once when the numbers arrive and then holds — animating on
/// every rebuild would make the bars twitch through the rest of the run.
class _ComparisonBars extends StatelessWidget {
  const _ComparisonBars({required this.cpu, required this.gpu});

  final double cpu;
  final double gpu;

  @override
  Widget build(BuildContext context) {
    final max = (cpu > gpu ? cpu : gpu);
    // A zero maximum (both runs failed) would divide by zero below; guard it
    // rather than letting the layout throw.
    final scale = max <= 0 ? 1.0 : max;

    return Column(
      children: [
        _Bar(
          label: 'CPU',
          value: cpu,
          fraction: (cpu / scale).clamp(0.0, 1.0),
          color: AppColors.accent,
        ),
        const SizedBox(height: 10),
        _Bar(
          label: 'GPU',
          value: gpu,
          fraction: (gpu / scale).clamp(0.0, 1.0),
          color: AppColors.brand,
        ),
      ],
    );
  }
}

/// One labelled throughput bar.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.label,
    required this.value,
    required this.fraction,
    required this.color,
  });

  final String label;
  final double value;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: fraction),
      duration: AppMotion.slow,
      curve: AppMotion.emphasized,
      builder: (context, t, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label, style: theme.textTheme.labelMedium),
                const Spacer(),
                Text(
                  '${value.toStringAsFixed(1)} tok/s',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: t,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The single-result bar, for a plain "Run benchmark".
class _SingleBar extends StatelessWidget {
  const _SingleBar({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return _Bar(
      label: label,
      value: value,
      fraction: 1.0,
      color: AppColors.accent,
    );
  }
}

/// Plain-language reading of the two numbers.
///
/// "GPU won by 12%" is the raw result; "about the same, so the CPU is fine"
/// is the decision. A user who offloads to a GPU for a 4% gain and then sees
/// their phone run hot has been told the wrong thing.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.cpu, required this.gpu});

  final double? cpu;
  final double? gpu;

  @override
  Widget build(BuildContext context) {
    final c = cpu;
    final g = gpu;
    if (c == null || g == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final bool gpuWins = g > c;
    final double ratio = gpuWins ? (c <= 0 ? 0 : g / c) : (g <= 0 ? 0 : c / g);
    final double pct = (ratio - 1) * 100;
    final String verdict;
    final Color tint;

    if (ratio < 1.15) {
      verdict = 'Both backends perform about the same on this phone, so the '
          'CPU is the safer choice — it runs cooler.';
      tint = scheme.onSurfaceVariant;
    } else if (gpuWins) {
      verdict = 'The GPU is ${pct.toStringAsFixed(0)}% faster here, so it '
          'has been selected.';
      tint = AppColors.brand;
    } else {
      verdict = 'The CPU is ${pct.toStringAsFixed(0)}% faster on this phone, '
          'which is common on midrange GPUs. It has been selected.';
      tint = AppColors.accent;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.insights_outlined, size: 16, color: tint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              verdict,
              style: theme.textTheme.bodySmall?.copyWith(color: tint),
            ),
          ),
        ],
      ),
    );
  }
}