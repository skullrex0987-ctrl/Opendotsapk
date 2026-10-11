/// GPU / accelerator capability detection.
///
/// The point of this file is to answer one question safely: *how many layers
/// can this phone actually offload?* Getting it wrong in the optimistic
/// direction means a crash or a black screen on someone else's hardware, so the
/// design is deliberately conservative and every value is a starting guess that
/// llama.cpp will override if the driver refuses.
///
/// ## Why Vulkan and not something vendor-specific
///
/// Android's only GPU compute API with broad, non-vendor-locked coverage is
/// Vulkan. It ships on essentially every SoC from roughly 2016 onward — Adreno
/// (Qualcomm), Mali (Arm), PowerVR (Imagination), Xclipse (Samsung, RDNA-based)
/// and the various Google Tensor parts all expose a Vulkan driver. That is the
/// "works on almost all phones" story, and it is the honest one: llama.cpp has
/// no portable NPU backend, and the OpenCL backend only ever helped Adreno.
///
/// NPU is a different matter. Every vendor ships a closed runtime — Qualcomm
/// QNN/Hexagon, MediaWiki NNAPI, Samsung ENN, Google Edge TPU — with different
/// SDKs, licences and quantization requirements. There is no single build that
/// reaches them. [npuVendor] reports what is present so the app can be honest in
/// its UI rather than pretending, and [npuUsable] is false everywhere until a
/// real backend is wired to a real runtime.
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// A coarse classification of the GPU, good enough to pick an offload policy.
enum GpuClass {
  /// Adreno, Mali, PowerVR, Xclipse — a Vulkan driver is expected.
  vulkanCapable,

  /// Emulator, x86, or a device too old to trust with GPU offload.
  unlikely,

  /// Could not be determined; try GPU, fall back to CPU.
  unknown,
}

enum NpuVendor { qualcomm, mediatek, samsung, google, huawei, none, unknown }

@immutable
class GpuCapability {
  final String socModel;
  final String hardware;
  final GpuClass gpuClass;
  final NpuVendor npuVendor;

  /// Total device RAM in MB, or 0 when unknown.
  final int totalRamMb;

  /// Layers this device should try to offload.
  ///
  /// Note this is a *default*, not a verdict. On many midrange Mali parts token
  /// generation is memory-bandwidth-bound and the CPU kernels are genuinely
  /// faster, so the UI offers a manual override and a benchmark rather than
  /// trusting this number.
  final int recommendedGpuLayers;

  /// True when the GPU is likely to *lose* to the CPU, so the default is to
  /// stay on the CPU and let the user opt in.
  final bool gpuOftenSlower;

  /// Plain-language explanation, shown in the UI.
  final String summary;

  const GpuCapability({
    required this.socModel,
    required this.hardware,
    required this.gpuClass,
    required this.npuVendor,
    required this.totalRamMb,
    required this.recommendedGpuLayers,
    required this.summary,
    this.gpuOftenSlower = false,
  });

  bool get npuUsable => false;

  String get gpuLabel => switch (gpuClass) {
    GpuClass.vulkanCapable => 'Vulkan-capable GPU',
    GpuClass.unlikely => 'No usable GPU detected',
    GpuClass.unknown => 'GPU capability unknown',
  };

  String get npuLabel => switch (npuVendor) {
    NpuVendor.qualcomm => 'Qualcomm Hexagon NPU present',
    NpuVendor.mediatek => 'MediaTek APU present',
    NpuVendor.samsung => 'Samsung ENN NPU present',
    NpuVendor.google => 'Google Tensor TPU present',
    NpuVendor.huawei => 'Huawei Da Vinci NPU present',
    NpuVendor.none => 'No NPU detected',
    NpuVendor.unknown => 'NPU capability unknown',
  };

  static const unknown = GpuCapability(
    socModel: 'unknown',
    hardware: 'unknown',
    gpuClass: GpuClass.unknown,
    npuVendor: NpuVendor.unknown,
    totalRamMb: 0,
    recommendedGpuLayers: 0,
    summary: 'Device information could not be read; running on CPU.',
  );
}

class GpuService {
  static GpuCapability? _cached;

  /// A fully offloaded 0.5B model is about 24 layers; large models are in the
  /// 30-45 range. 99 is llama.cpp's idiomatic "all of them", and it clamps to
  /// the model's actual depth, so it is the right value for a device we trust.
  static const int _allLayers = 99;

  /// Probe the device once and cache the result.
  static Future<GpuCapability> detect() async {
    if (_cached != null) return _cached!;

    // Tests and desktop builds have no Android device info.
    if (kIsWeb || !Platform.isAndroid) {
      _cached = GpuCapability.unknown;
      return _cached!;
    }

    try {
      final info = await DeviceInfoPlugin().androidInfo;

      final hardware = info.hardware.toLowerCase();
      final soc = _socName(info);
      final combined = '$soc $hardware'.toLowerCase();

      final gpuClass = _classifyGpu(combined, info);
      final npuVendor = _classifyNpu(combined);

      // device_info_plus 13 exposes the RAM figure directly (bytes).
      // v11's `physicalSize` no longer exists.
      final ramMb = info.physicalRamSize > 0
          ? (info.physicalRamSize / (1024 * 1024)).round()
          : 0;

      // Android's own low-RAM flag is a stronger signal than a byte count: the
      // platform sets it when it knows it will kill background work under
      // pressure, which is exactly the situation where holding GPU buffers
      // alongside the model gets the app killed.
      if (info.isLowRamDevice) {
        _cached = GpuCapability(
          socModel: soc,
          hardware: info.hardware,
          gpuClass: GpuClass.unlikely,
          npuVendor: npuVendor,
          totalRamMb: ramMb,
          recommendedGpuLayers: 0,
          summary:
              'Android reports this as a low-RAM device, so inference '
              'stays on the CPU and a small model is recommended.',
        );
        return _cached!;
      }

      // Midrange Mali parts are the well-documented case where GPU token
      // generation loses to the CPU: generation is memory-bandwidth-bound, and
      // a mobile GPU with a narrow bus does not beat well-vectorised NEON
      // kernels. Do not silently pick the slower path for these users.
      final maliCautious =
          combined.contains('mali') &&
          !combined.contains('immortalis') &&
          !combined.contains('g715') &&
          !combined.contains('g720');

      final layers = maliCautious ? 0 : _layersFor(gpuClass, ramMb);

      _cached = GpuCapability(
        socModel: soc,
        hardware: info.hardware,
        gpuClass: gpuClass,
        npuVendor: npuVendor,
        totalRamMb: ramMb,
        recommendedGpuLayers: layers,
        gpuOftenSlower: maliCautious,
        summary: maliCautious
            ? 'A midrange Mali GPU was detected. On these, token generation is '
                  'memory-bandwidth-bound and the CPU kernels are usually faster, '
                  'so the CPU is used by default. You can try the GPU in '
                  'Performance and compare.'
            : _summaryFor(gpuClass, layers, ramMb),
      );
    } catch (e) {
      debugPrint('[GpuService] detection failed: $e');
      _cached = GpuCapability.unknown;
    }

    return _cached!;
  }

  /// Best-effort human-readable SoC name.
  ///
  /// The plugin exposes the board name rather than a marketing chipset name, so
  /// this is not prettified beyond stripping the board prefixes — inventing a
  /// friendly name that is wrong would be worse than showing the raw one.
  static String _socName(AndroidDeviceInfo info) {
    final board = info.board.trim();
    if (board.isNotEmpty && board.toLowerCase() != 'unknown') return board;
    final model = info.model.trim();
    return model.isNotEmpty ? model : 'unknown';
  }

  static GpuClass _classifyGpu(String s, AndroidDeviceInfo info) {
    // Emulators are the most common source of "it compiled but the GPU backend
    // produced nothing useful". Treat them as CPU-only.
    if (s.contains('goldfish') ||
        s.contains('ranchu') ||
        s.contains('emulator') ||
        s.contains('sdk_gphone')) {
      return GpuClass.unlikely;
    }

    if (info.isPhysicalDevice == false) return GpuClass.unlikely;

    const knownGpuMarkers = [
      'adreno', // Qualcomm
      'mali', // Arm
      'powervr', // Imagination
      'xclipse', // Samsung / AMD RDNA
      'immortalis', // Arm, newer Mali branding
      'videocore', // Broadcom (Raspberry Pi class)
      'tensor', // Google Tensor
      'exynos', // Samsung
      'mt', // MediaTek (mtxxxx, dimensity)
      'dimensity',
      'snapdragon',
      'sm8', // Snapdragon 8xx board prefix
      'sdm',
      'msm',
      'kirin', // Huawei
      'tensor',
    ];

    if (knownGpuMarkers.any(s.contains)) return GpuClass.vulkanCapable;

    // Unknown but real hardware: worth attempting, llama.cpp falls back safely.
    return GpuClass.unknown;
  }

  static NpuVendor _classifyNpu(String s) {
    if (s.contains('snapdragon') ||
        s.contains('adreno') ||
        s.contains('sm8') ||
        s.contains('sdm') ||
        s.contains('msm') ||
        s.contains('qcom')) {
      return NpuVendor.qualcomm;
    }
    if (s.contains('mediatek') ||
        s.contains('dimensity') ||
        s.contains('mt6') ||
        s.contains('mt8')) {
      return NpuVendor.mediatek;
    }
    if (s.contains('exynos') ||
        s.contains('samsung') ||
        s.contains('xclipse')) {
      return NpuVendor.samsung;
    }
    if (s.contains('tensor') || s.contains('google')) return NpuVendor.google;
    if (s.contains('kirin') || s.contains('huawei')) return NpuVendor.huawei;
    return NpuVendor.unknown;
  }

  static int _layersFor(GpuClass cls, int ramMb) {
    switch (cls) {
      case GpuClass.unlikely:
        return 0;
      case GpuClass.vulkanCapable:
      case GpuClass.unknown:
        // Below ~4 GB the model plus a GPU driver's own allocations is a real
        // risk of the low-memory killer stepping in; keep it on the CPU.
        if (ramMb > 0 && ramMb < 4000) return 0;
        return _allLayers;
    }
  }

  static String _summaryFor(GpuClass cls, int layers, int ramMb) {
    final ram = ramMb > 0 ? '${(ramMb / 1024).toStringAsFixed(1)} GB RAM' : '';
    switch (cls) {
      case GpuClass.unlikely:
        return 'Running entirely on the CPU. This is an emulator or a device '
                'without a usable GPU driver$ram.'
            .trim();
      case GpuClass.vulkanCapable:
        return layers > 0
            ? 'GPU acceleration enabled — offloading all layers to the GPU'
                  '${ram.isEmpty ? '' : ' ($ram)'}.'
            : 'A GPU is present, but $ram is not enough to offload safely, so '
                  'the CPU is being used.';
      case GpuClass.unknown:
        return layers > 0
            ? 'The GPU was not identified, but acceleration is being attempted '
                  'and will fall back to the CPU if the driver refuses.'
            : 'The GPU was not identified; running on the CPU.';
    }
  }

  /// Called from tests to reset the memoised probe.
  @visibleForTesting
  static void resetCache() => _cached = null;

  /// Resolve the offload setting — 'auto' | 'gpu' | 'cpu' — to a layer count.
  ///
  /// This is the single place that decides, so the Performance screen and the
  /// model loader can never disagree about what the user asked for.
  static Future<int> layersForMode(String mode) async {
    switch (mode) {
      case 'gpu':
        // llama.cpp clamps to the model's actual depth, so 99 means "all".
        return _allLayers;
      case 'cpu':
        return 0;
      default:
        return (await detect()).recommendedGpuLayers;
    }
  }
}
