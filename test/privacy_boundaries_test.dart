/// Privacy-boundary tests (audit task B5).
///
/// These pin the properties that make "privacy-first" a fact rather than a
/// slogan: a fresh install can never reach the cloud, private mode performs no
/// network call at all, cloud use is gated behind per-destination consent, the
/// per-message "cloud once" affordance cannot override private mode, and the
/// erase flow requires two real confirmations.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/router_service.dart';
import 'package:localmind/domain/models/cloud_provider.dart';
import 'package:localmind/presentation/providers/providers.dart';

void main() {
  late RouterService router;

  setUp(() {
    router = RouterService.instance;
    router.isOnline = true;
    router.isMetered = false;
    router.privateMode = false;
    router.setCandidates(const []);
    dnsLookupOverride = null;
  });

  tearDown(() {
    dnsLookupOverride = null;
    router.privateMode = false;
  });

  ({CloudProvider provider, String modelId}) openAi() =>
      (provider: CloudCatalog.byId('openai')!, modelId: 'gpt-4o-mini');

  // --------------------------------------------------------------------------
  // 1. Local-only default: a brand-new install with no key never goes to cloud.
  // --------------------------------------------------------------------------
  group('local-only default (fresh install, no cloud key)', () {
    test('never constructs a cloud request for any mode, prompt or input', () {
      // No candidates == no provider configured == a fresh install.
      router.setCandidates(const []);

      const prompts = [
        'hi',
        'explain quantum mechanics',
        'def parse(s): return s[::-1]',
        'prove the halting problem is undecidable',
        'my password is hunter2',
        'summarize this document',
        'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
            'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
      ];

      for (final mode in ['local', 'auto', 'cloud']) {
        for (final prompt in prompts) {
          for (final hasImages in [false, true]) {
            for (final localModelReady in [true, false]) {
              final d = router.decide(
                prompt: prompt,
                config: RoutingConfig(mode: mode),
                hasImages: hasImages,
                localVisionReady: false,
                localModelReady: localModelReady,
              );
              expect(
                d.isCloud,
                isFalse,
                reason:
                    'mode=$mode promptLen=${prompt.length} '
                    'images=$hasImages modelReady=$localModelReady',
              );
              // The privacy promise is "nothing leaves the device", and a
              // refusal honours it just as strictly as a local answer does.
              //
              // An image turn with no vision cannot be served at all: handing
              // the picture to a text model means the plugin discards it and
              // the model answers a question it never received. So the expected
              // target is `refused` for image turns and `local` otherwise — and
              // never `cloud` under any combination, which is what this test
              // exists to prove.
              final expectsRefusal = hasImages;
              expect(
                d.isRefused,
                expectsRefusal,
                reason:
                    'mode=$mode images=$hasImages modelReady=$localModelReady',
              );
              expect(
                d.target,
                expectsRefusal ? RouteTarget.refused : RouteTarget.local,
                reason:
                    'mode=$mode images=$hasImages modelReady=$localModelReady',
              );
            }
          }
        }
      }
    });

    test('hasCloud is false with no candidates', () {
      expect(router.hasCloud, isFalse);
    });
  });

  // --------------------------------------------------------------------------
  // 4. Private mode: no network call, not even a DNS probe.
  // --------------------------------------------------------------------------
  group('private mode', () {
    test('overrides a configured provider in every mode', () {
      router.setCandidates([openAi()]);
      for (final mode in ['local', 'auto', 'cloud']) {
        final d = router.decide(
          prompt: 'x' * 5000,
          config: RoutingConfig(mode: mode, privateMode: true),
          localModelReady: true,
        );
        expect(d.isCloud, isFalse, reason: 'mode=$mode');
      }
    });

    test('performs no DNS lookup on the connectivity probe', () async {
      var lookups = 0;
      dnsLookupOverride = (host) async {
        lookups++;
        return <InternetAddress>[];
      };

      router.privateMode = true;
      router.isOnline = true;

      final online = await router.probeConnectivity();

      expect(lookups, 0, reason: 'private mode must not touch the network');
      expect(online, isTrue);
      expect(router.isOnline, isTrue);
    });

    test('outside private mode the probe does perform the lookup', () async {
      var lookups = 0;
      dnsLookupOverride = (host) async {
        lookups++;
        return <InternetAddress>[];
      };

      router.privateMode = false;
      await router.probeConnectivity();

      expect(lookups, 1);
    });
  });

  // --------------------------------------------------------------------------
  // 3. Per-message "send to cloud just this once".
  // --------------------------------------------------------------------------
  group('per-message cloud-once', () {
    test('forces cloud for the turn when armed', () {
      router.setCandidates([openAi()]);
      final cfg = routeConfigForTurn(
        mode: 'auto',
        privateMode: false,
        preferLocalOnMetered: true,
        sendToCloudOnce: true,
      );
      final d = router.decide(prompt: 'hi', config: cfg, localModelReady: true);
      expect(d.isCloud, isTrue);
    });

    test('is overruled by private mode', () {
      router.setCandidates([openAi()]);
      final cfg = routeConfigForTurn(
        mode: 'auto',
        privateMode: true,
        preferLocalOnMetered: true,
        sendToCloudOnce: true,
      );
      expect(cfg.mode, isNot('cloud'));
      final d = router.decide(prompt: 'hi', config: cfg, localModelReady: true);
      expect(d.isCloud, isFalse);
    });

    test('still refuses cloud when no provider is configured', () {
      router.setCandidates(const []);
      final cfg = routeConfigForTurn(
        mode: 'auto',
        privateMode: false,
        preferLocalOnMetered: true,
        sendToCloudOnce: true,
      );
      final d = router.decide(prompt: 'hi', config: cfg, localModelReady: true);
      expect(d.isCloud, isFalse);
    });

    test('leaves the saved mode alone when not armed', () {
      final cfg = routeConfigForTurn(
        mode: 'auto',
        privateMode: false,
        preferLocalOnMetered: false,
        sendToCloudOnce: false,
      );
      expect(cfg.mode, 'auto');
      expect(cfg.preferLocalOnMetered, isFalse);
    });

    test('the once flag is consumed after one turn', () {
      final once = CloudOnceNotifier();
      expect(once.consume(), isFalse);
      once.armForNextMessage();
      expect(once.consume(), isTrue);
      // A single arm cannot leak a second turn.
      expect(once.consume(), isFalse);
    });
  });

  // --------------------------------------------------------------------------
  // 2. Consent is required, per destination, and re-required if it changes.
  // --------------------------------------------------------------------------
  group('cloud consent', () {
    test('is granted per provider and not inherited by another', () {
      final settings = <String, dynamic>{'cloud_consent_provider': 'openai'};
      expect(cloudConsentGranted(settings, 'openai'), isTrue);
      expect(cloudConsentGranted(settings, 'anthropic'), isFalse);
    });

    test('is not granted with no provider or no stored consent', () {
      expect(cloudConsentGranted({}, 'openai'), isFalse);
      expect(
        cloudConsentGranted({'cloud_consent_provider': null}, 'openai'),
        isFalse,
      );
      expect(
        cloudConsentGranted({'cloud_consent_provider': ''}, 'openai'),
        isFalse,
      );
      expect(
        cloudConsentGranted({'cloud_consent_provider': 'openai'}, null),
        isFalse,
      );
    });

    test('consent text names the provider and every payload', () {
      final body = CloudPrivacy.consentBody('Anthropic');
      expect(body, contains('Anthropic'));
      for (final item in CloudPrivacy.leavesDevice) {
        expect(body, contains(item), reason: 'consent must mention "$item"');
      }
    });

    test('the stated payload covers prompt, history, documents and images', () {
      final joined = CloudPrivacy.leavesDevice.join(' ').toLowerCase();
      expect(joined, contains('prompt'));
      expect(joined, contains('conversation history'));
      expect(joined, contains('document'));
      expect(joined, contains('image'));
    });
  });

  // --------------------------------------------------------------------------
  // 5. Erase-all-data confirmation is genuinely two steps.
  // --------------------------------------------------------------------------
  group('two-step erase confirmation', () {
    test('a lone second confirmation does not count', () {
      final gate = TwoStepConfirm();
      expect(gate.confirmSecond(), isFalse);
      expect(gate.awaitingSecond, isFalse);
    });

    test('counts only after the first step, and only once', () {
      final gate = TwoStepConfirm();
      gate.confirmFirst();
      expect(gate.awaitingSecond, isTrue);
      expect(gate.confirmSecond(), isTrue);
      // Consumed: a second erase would need both steps again.
      expect(gate.confirmSecond(), isFalse);
    });

    test('cancelling clears the gate', () {
      final gate = TwoStepConfirm();
      gate.confirmFirst();
      gate.cancel();
      expect(gate.awaitingSecond, isFalse);
      expect(gate.confirmSecond(), isFalse);
    });
  });
}
