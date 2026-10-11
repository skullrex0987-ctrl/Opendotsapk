/// Tests for the on-device model catalogue.
///
/// A wrong entry here costs the user a several-hundred-megabyte download that
/// can never load, so the byte totals and the support flags are asserted rather
/// than assumed. The Moondream2 case is the cautionary tale: it shipped for
/// months as the only vision option despite the runtime having no encoder for
/// its projector at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/domain/models/local_model.dart';

void main() {
  group('catalogue integrity', () {
    test('every id is unique', () {
      final ids = ModelCatalog.all.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every remote file is https', () {
      for (final m in ModelCatalog.all) {
        for (final f in m.files) {
          expect(
            f.url.startsWith('https://'),
            isTrue,
            reason: '${m.id} -> ${f.name}',
          );
        }
      }
    });

    test('a usable vision model always declares a projector', () {
      for (final m in ModelCatalog.visionModels.where(ModelCatalog.isUsable)) {
        expect(m.projectorFileName, isNotNull, reason: m.id);
        expect(m.projectorUrl, isNotNull, reason: m.id);
      }
    });

    test('byId resolves every catalogue entry', () {
      for (final m in ModelCatalog.all) {
        expect(ModelCatalog.byId(m.id)?.id, m.id);
      }
      expect(ModelCatalog.byId('does-not-exist'), isNull);
      expect(ModelCatalog.byId(null), isNull);
    });

    test('sizeLabel is human readable for every entry', () {
      for (final m in ModelCatalog.all) {
        expect(m.sizeLabel, matches(RegExp(r'^\d+(\.\d+)? (MB|GB)$')), reason: m.id);
      }
    });
  });

  group('Qwen3.5 0.8B', () {
    test('is present, usable, and offered first for vision', () {
      final m = ModelCatalog.qwen35_08b;
      expect(m.kind, ModelKind.vision);
      expect(ModelCatalog.isUsable(m), isTrue);
      expect(ModelCatalog.visionModels.first.id, m.id);
      expect(ModelCatalog.defaultVision.id, m.id);
    });

    test('byte total covers weights AND projector', () {
      // 532,517,120 B weights + 204,987,232 B mmproj, read from the Hugging Face
      // tree API. Getting this wrong is what made an earlier vision entry
      // download only half of itself.
      final m = ModelCatalog.qwen35_08b;
      expect(m.approxBytes, 532517120 + 204987232);
    });

    test('is offered as a chat brain too, since it is one model', () {
      expect(ModelCatalog.byId(ModelCatalog.qwen35_08b.id), isNotNull);
      expect(ModelCatalog.qwen35_08b.isVision, isTrue);
    });
  });

  group('Moondream2', () {
    test('is disabled rather than silently missing', () {
      final m = ModelCatalog.moondream2;
      expect(ModelCatalog.isUsable(m), isFalse);
      expect(m.unsupportedReason, isNotNull);
      // Still listed, so the UI can explain *why* it is unavailable.
      expect(ModelCatalog.visionModels.map((e) => e.id), contains(m.id));
    });

    test('the reason names the actual cause', () {
      expect(
        ModelCatalog.moondream2.unsupportedReason!.toLowerCase(),
        contains('vision encoder'),
      );
    });
  });

  group('isUsable', () {
    test('is driven purely by unsupportedReason', () {
      for (final m in ModelCatalog.all) {
        expect(
          ModelCatalog.isUsable(m),
          m.unsupportedReason == null,
          reason: m.id,
        );
      }
    });
  });
}
