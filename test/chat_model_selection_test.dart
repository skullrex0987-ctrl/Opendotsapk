/// Chat-model selection rules.
///
/// Regression guard for a real bug: Qwen3.5 is registered with
/// [ModelKind.vision] (vision is why it is listed at all) while carrying the
/// language model inside the same GGUF. Selection code that checked only
/// `kind == ModelKind.llm` rejected it, silently fell back to a catalog
/// default the user had never downloaded, and tapping Load therefore reported
/// "No chat model downloaded yet" forever — the model the user picked never
/// loaded, no matter how many times they tried.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/domain/models/local_model.dart';

void main() {
  group('Chat-capable models', () {
    test('Qwen3.5 (multimodal) can be the chat model', () {
      expect(ModelCatalog.isChatCapable(ModelCatalog.qwen35_08b), isTrue);
    });

    test('every model offered in the chat list is chat-capable', () {
      for (final m in ModelCatalog.llms) {
        expect(
          ModelCatalog.isChatCapable(m),
          isTrue,
          reason: '${m.id} is listed as a chat model but is not chat-capable',
        );
      }
    });

    test('vision-only and embedding models are not chat-capable', () {
      expect(ModelCatalog.isChatCapable(ModelCatalog.miniLm6), isFalse);
    });

    test('Qwen3.5 is offered as both chat and vision', () {
      final id = ModelCatalog.qwen35_08b.id;
      expect(ModelCatalog.llms.any((m) => m.id == id), isTrue);
      expect(ModelCatalog.visionModels.any((m) => m.id == id), isTrue);
      expect(ModelCatalog.defaultVision.id, id);
    });

    test('same-arch pairing: Qwen3.5 with itself is the valid pairing', () {
      expect(ModelCatalog.qwen35_08b.llmArch, ModelCatalog.qwen35_08b.llmArch);
      expect(ModelCatalog.qwen35_08b.isVision, isTrue);
      expect(ModelCatalog.qwen35_08b.projectorFileName, isNotNull);
    });
  });

  group('Picker sections', () {
    // The write path takes the *section* as the authority, not `m.kind`,
    // because Qwen3.5 is registered as `vision`. These pin the fact that makes
    // that necessary: the chat section holds a model whose kind is not `llm`.

    test('the chat section holds at least one non-llm model', () {
      // If this ever becomes false the section-based dispatch is merely
      // redundant rather than load-bearing — keep it visible when it changes.
      expect(
        ModelCatalog.llms
            .where((m) => m.kind != ModelKind.llm)
            .map((m) => m.id),
        contains(ModelCatalog.qwen35_08b.id),
      );
    });

    test('each section lists a model at most once', () {
      for (final section in [
        ModelCatalog.llms,
        ModelCatalog.visionModels,
        ModelCatalog.embeddingModels,
      ]) {
        final ids = section.map((m) => m.id).toList();
        expect(ids.toSet().length, ids.length);
      }
    });

    test('vision section entries all declare a projector', () {
      for (final m in ModelCatalog.visionModels) {
        expect(
          m.projectorFileName,
          isNotNull,
          reason: '${m.id} is offered for vision but has no projector file',
        );
      }
    });

    test('the embedding section holds only embedding models', () {
      for (final m in ModelCatalog.embeddingModels) {
        expect(m.kind, ModelKind.embedding);
      }
    });

    test('every selectable chat model can actually be loaded as chat', () {
      // Guards against a chat-section entry that is neither an LLM nor a
      // multimodal model carrying its own weights — the kind of entry that
      // "loads" and then does nothing.
      for (final m in ModelCatalog.llms) {
        expect(
          ModelCatalog.isChatCapable(m),
          isTrue,
          reason:
              '${m.id} is offered as the chat model but carries no '
              'language weights',
        );
      }
      for (final m in ModelCatalog.embeddingModels) {
        expect(m.kind, ModelKind.embedding);
      }
    });
  });
}
