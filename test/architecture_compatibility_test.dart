/// Architecture compatibility tests for LLM–vision projector pairing.
///
/// Qwen3.5 carries vision in its own architecture (qwen35), so pairing it with
/// a different LLM (phi2, qwen2) is a runtime failure: the projector expects
/// qwen35 context and the LLM speaks a different language.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/domain/models/local_model.dart';

void main() {
  group('Architecture compatibility', () {
    test('Qwen3.5 vision is compatible with itself', () {
      expect(
          _isArchCompatible(ModelCatalog.qwen35_08b, ModelCatalog.qwen35_08b),
          isTrue);
    });

    test('Qwen3.5 vision is incompatible with SmolLM2', () {
      expect(
          _isArchCompatible(
              ModelCatalog.smolLm2_360m, ModelCatalog.qwen35_08b),
          isFalse);
    });

    test('Qwen3.5 vision is incompatible with Qwen2.5', () {
      expect(
          _isArchCompatible(
              ModelCatalog.qwen05b, ModelCatalog.qwen35_08b),
          isFalse);
    });

    test('Same-arch models are compatible', () {
      expect(
          _isArchCompatible(ModelCatalog.qwen05b, ModelCatalog.qwen15b),
          isTrue);
    });

    test('Models without arch are permissive', () {
      // If we don't know the arch, we allow it (better to fail at load time
      // than to block a potentially valid pairing).
      final unknown = const LocalModel(
        id: 'unknown',
        displayName: 'Unknown',
        description: 'Unknown arch',
        kind: ModelKind.llm,
        fileName: 'unknown.gguf',
        url: 'https://example.com/unknown.gguf',
        approxBytes: 1000000,
      );
      expect(
          _isArchCompatible(unknown, ModelCatalog.qwen35_08b), isTrue);
    });
  });
}

/// Mirrors the check in _ModelPickerBodyState._isVisionArchIncompatible.
bool _isArchCompatible(LocalModel chat, LocalModel vision) {
  if (vision.llmArch == null) return true;
  if (chat.id == vision.id) return true;
  final chatArch = chat.llmArch;
  if (chatArch == null) return true;
  return chatArch == vision.llmArch;
}

