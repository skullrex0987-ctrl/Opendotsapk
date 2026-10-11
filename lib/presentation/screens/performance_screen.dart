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
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/gpu_service.dart';
import '../../data/services/llm_service.dart';
import '../providers/providers.dart';

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
          const SizedBox(height: 12),
          _backendCard(settings, llm),
          const SizedBox(height: 12),
          _threadsCard(settings),
          const SizedBox(height: 12),
          _benchmarkCard(llm),
          const SizedBox(height: 12),
          _npuCard(),
        ],
      ),
    );
  }

  Widget _deviceCard(LlmService llm) {
    if (_loadingDevice) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This device',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            _row('System on chip', gpu.socModel),
            _row('Hardware', gpu.hardware),
            _row('Memory', ram),
            _row('GPU', gpu.gpuLabel),
            _row('Backend', backendLabel),
            _row('Layers offloaded', '${llm.gpuLayers}'),
            _row('CPU threads', '${llm.threads}'),
            const SizedBox(height: 10),
            Text(
              gpu.summary,
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backendCard(Map<String, dynamic> settings, LlmService llm) {
    final mode = '${settings['gpu_offload'] ?? 'auto'}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Compute backend',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'gpu', label: Text('GPU')),
                ButtonSegment(value: 'cpu', label: Text('CPU')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => _setMode(s.first),
            ),
            const SizedBox(height: 10),
            Text(
              _modeExplanation(mode),
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
            const SizedBox(height: 8),
            Text(
              'Changing this reloads the model — takes a few seconds.',
              style: TextStyle(fontSize: 11, color: Colors.grey[600]),
            ),
          ],
        ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'CPU Threads',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Controls how many CPU cores are used for inference. More threads '
              'can speed up prompt processing but may slow down token generation '
              'on memory-bandwidth-bound workloads. $current is a good starting point.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Threads:', style: TextStyle(fontSize: 13)),
                const SizedBox(width: 12),
                Expanded(
                  child: Slider(
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
                ),
                Text('$current', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ],
        ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Benchmark',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Generates a short reply and measures throughput. Run it on the '
              'CPU and on the GPU to see which is genuinely faster on your '
              'phone.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
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
              onPressed: (_benchmarking || !llm.isLoaded)
                  ? null
                  : _autoBenchmark,
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
              const SizedBox(height: 8),
              Text(
                'Load a model first.',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ],
            if (_benchmarkResult != null) ...[
              const SizedBox(height: 12),
              Text(
                _benchmarkResult!,
                style: const TextStyle(fontSize: 13, height: 1.4),
              ),
            ],
          ],
        ),
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Neural accelerator',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('not used', style: TextStyle(fontSize: 10)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(gpu.npuLabel, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text(
              'Every phone NPU needs its own vendor runtime — Qualcomm QNN, '
              'MediaTek NeuroPilot, Samsung ENN, Google Edge TPU — with '
              'different SDKs and licences and no common build target. There is '
              'no portable NPU backend for llama.cpp, so claiming NPU '
              'acceleration here would be a lie. This app uses the GPU '
              '(Vulkan) or the CPU.',
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: Colors.grey[500],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
