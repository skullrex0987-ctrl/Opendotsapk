/// Tests for the GPU offload policy.
///
/// The device probe itself needs real hardware, so these cover the part that is
/// pure logic: how a backend choice turns into a layer count. That mapping
/// matters because it is the single point the settings UI and the model loader
/// both go through — if it regresses, a user who selects "CPU" silently keeps
/// offloading, or the reverse, and nothing else would catch it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/gpu_service.dart';

void main() {
  group('GpuService.layersForMode', () {
    test("'cpu' never offloads, whatever the device says", () async {
      expect(await GpuService.layersForMode('cpu'), 0);
    });

    test("'gpu' requests full offload and lets llama.cpp clamp it", () async {
      // 99 is llama.cpp's idiomatic "all layers"; it clamps to the model depth.
      expect(await GpuService.layersForMode('gpu'), 99);
    });

    test(
      'an unrecognised mode falls back to auto rather than crashing',
      () async {
        // A stale preference string from an older build must not break loading.
        GpuService.resetCache();
        final layers = await GpuService.layersForMode('nonsense');
        expect(layers, greaterThanOrEqualTo(0));
      },
    );
  });

  group('GpuCapability', () {
    test('no NPU is ever reported as usable', () {
      // There is no portable llama.cpp NPU backend, so this must stay false
      // until a real one exists. Claiming otherwise would be a lie in the UI.
      const capability = GpuCapability(
        socModel: 'test',
        hardware: 'test',
        gpuClass: GpuClass.vulkanCapable,
        npuVendor: NpuVendor.qualcomm,
        totalRamMb: 8192,
        recommendedGpuLayers: 99,
        summary: 'test',
      );
      expect(capability.npuUsable, isFalse);
    });

    test('the unknown capability is safe: no offload, no claims', () {
      expect(GpuCapability.unknown.recommendedGpuLayers, 0);
      expect(GpuCapability.unknown.npuUsable, isFalse);
      expect(GpuCapability.unknown.totalRamMb, 0);
    });
  });
}
