/// Tests for the local/cloud router.
///
/// The router is the only thing standing between "privacy-first" being a real
/// property and it being a slogan, so the hard rules get the most attention.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/router_service.dart';
import 'package:localmind/domain/models/cloud_provider.dart';

void main() {
  late RouterService router;

  setUp(() {
    router = RouterService.instance;
    router.isOnline = true;
    router.isMetered = false;
    router.setCandidates(const []);
  });

  ({CloudProvider provider, String modelId}) openAi() =>
      (provider: CloudCatalog.byId('openai')!, modelId: 'gpt-4o-mini');

  ({CloudProvider provider, String modelId}) anthropic() =>
      (provider: CloudCatalog.byId('anthropic')!,
          modelId: 'claude-3-5-haiku-latest');

  const auto = RoutingConfig(mode: 'auto');

  group('hard rules', () {
    test('no provider configured always stays local', () {
      final d = router.decide(prompt: 'hello', config: auto);
      expect(d.isCloud, isFalse);
      expect(d.forced, isTrue);
    });

    test('private mode overrides a configured cloud provider', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'explain quantum computing in depth',
        config: const RoutingConfig(mode: 'auto', privateMode: true),
      );
      expect(d.isCloud, isFalse);
      expect(d.reason.toLowerCase(), contains('private'));
    });

    test('private mode overrides explicit cloud mode', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'hi',
        config: const RoutingConfig(mode: 'cloud', privateMode: true),
      );
      expect(d.isCloud, isFalse);
    });

    test('offline forces local even with a provider and cloud mode', () {
      router.setCandidates([openAi()]);
      router.isOnline = false;
      final d = router.decide(
        prompt: 'anything',
        config: const RoutingConfig(mode: 'cloud'),
      );
      expect(d.isCloud, isFalse);
      expect(d.reason.toLowerCase(), contains('offline'));
    });

    test('image with no local vision but a vision provider goes to cloud', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'what is this',
        config: auto,
        hasImages: true,
        localVisionReady: false,
        localModelReady: true,
      );
      expect(d.isCloud, isTrue);
      expect(d.provider?.id, 'openai');
    });

    test('image with no vision anywhere is refused, never quietly downgraded', () {
      // Neither a text-only provider nor a text-only local model can see the
      // picture. Asking either one returns a confident answer to a question
      // that was never actually asked, so the turn must be refused instead.
      router.setCandidates([
        (provider: CloudCatalog.byId('deepseek')!, modelId: 'deepseek-chat'),
      ]);
      final d = router.decide(
        prompt: 'what is this',
        config: auto,
        hasImages: true,
        localVisionReady: false,
        localModelReady: true,
      );
      expect(d.isCloud, isFalse);
      expect(d.isRefused, isTrue);
      expect(d.reason.toLowerCase(), contains('no vision model'));
    });

    test('a refused image turn never falls back to the local text model', () {
      // Regression guard: this used to return RouteTarget.local with a reason
      // string, which then sent the image to a text model that silently
      // discarded it.
      router.setCandidates(const []);
      final d = router.decide(
        prompt: 'look at this',
        config: auto,
        hasImages: true,
        localVisionReady: false,
        localModelReady: true,
      );
      expect(d.target, RouteTarget.refused);
      expect(d.isRefused, isTrue);
    });

    test('image with local vision stays eligible for local', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'what is this',
        config: auto,
        hasImages: true,
        localVisionReady: true,
        localModelReady: true,
      );
      expect(d.isCloud, isFalse);
    });

    test('no local model loaded falls back to cloud when available', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'hello',
        config: auto,
        localModelReady: false,
      );
      expect(d.isCloud, isTrue);
    });
  });

  group('explicit modes', () {
    test('local mode never uses cloud', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'write a complex algorithm with a proof',
        config: const RoutingConfig(mode: 'local'),
        localModelReady: true,
      );
      expect(d.isCloud, isFalse);
    });

    test('cloud mode always uses cloud when a key exists', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'hi',
        config: const RoutingConfig(mode: 'cloud'),
        localModelReady: true,
      );
      expect(d.isCloud, isTrue);
    });
  });

  group('auto scoring', () {
    test('short conversational turns stay local', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'what time is it',
        config: auto,
        localModelReady: true,
      );
      expect(d.isCloud, isFalse);
    });

    test('long input pushes to cloud', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'x' * 2000,
        config: auto,
        localModelReady: true,
      );
      expect(d.isCloud, isTrue);
    });

    test('code requests push to cloud', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'def parse(s): return s[::-1]',
        config: auto,
        localModelReady: true,
      );
      expect(d.isCloud, isTrue);
    });

    test('personal-data phrasing keeps it local', () {
      router.setCandidates([openAi()]);
      final d = router.decide(
        prompt: 'summarize the conversation about my bank account',
        config: auto,
        localModelReady: true,
      );
      expect(d.isCloud, isFalse);
    });

    test('metered connection biases toward local', () {
      router.setCandidates([openAi()]);
      router.isMetered = true;
      final d = router.decide(
        prompt: 'please debug this stack trace',
        config: auto,
        localModelReady: true,
      );
      expect(d.isCloud, isFalse);
    });

    test('metered bias can be turned off', () {
      router.setCandidates([openAi()]);
      router.isMetered = true;
      final d = router.decide(
        prompt: 'x' * 2000,
        config: const RoutingConfig(
          mode: 'auto',
          preferLocalOnMetered: false,
        ),
        localModelReady: true,
      );
      expect(d.isCloud, isTrue);
    });

    test('every decision carries a human-readable reason', () {
      router.setCandidates([openAi()]);
      for (final p in ['hi', 'x' * 2000, 'debug this', 'my password is x']) {
        final d = router.decide(
          prompt: p,
          config: auto,
          localModelReady: true,
        );
        expect(d.reason, isNotEmpty);
      }
    });
  });

  group('catalog', () {
    test('every provider has at least one model', () {
      for (final p in CloudCatalog.providers) {
        expect(p.models, isNotEmpty, reason: '${p.id} has no models');
      }
    });

    test('provider ids are unique', () {
      final ids = CloudCatalog.providers.map((p) => p.id).toSet();
      expect(ids.length, CloudCatalog.providers.length);
    });

    test('model ids are unique within a provider', () {
      for (final p in CloudCatalog.providers) {
        final ids = p.models.map((m) => m.id).toSet();
        expect(ids.length, p.models.length, reason: '${p.id} has duplicates');
      }
    });

    test('byId finds known providers and returns null otherwise', () {
      expect(CloudCatalog.byId('openai')?.displayName, 'OpenAI');
      expect(CloudCatalog.byId('nope'), isNull);
    });

    test('every provider exposes a default model', () {
      for (final p in CloudCatalog.providers) {
        expect(p.defaultModel.id, isNotEmpty);
      }
    });

    test('vision-capable providers declare it', () {
      final openai = CloudCatalog.byId('openai')!;
      expect(openai.models.first.supportsVision, isTrue);
    });

    test('base urls are https except local servers', () {
      for (final p in CloudCatalog.providers) {
        if (p.id == 'ollama' || p.id == 'custom') continue;
        expect(p.defaultBaseUrl.startsWith('https://'), isTrue,
            reason: '${p.id} must not use plaintext http');
      }
    });

    test('vision candidate is found across the configured set', () {
      router.setCandidates([openAi(), anthropic()]);
      expect(router.visionCandidate, isNotNull);
    });

    test('no vision candidate when only text models are configured', () {
      router.setCandidates([
        (provider: CloudCatalog.byId('groq')!, modelId: 'llama-3.1-8b-instant'),
      ]);
      expect(router.visionCandidate, isNull);
    });
  });
}
