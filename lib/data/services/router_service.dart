/// Chooses between the on-device model and a cloud provider for each turn.
///
/// This is the piece that keeps LocalMind's privacy promise intact while still
/// letting the user reach for a big model when they need one. The rules are
/// deliberately boring and inspectable — a router nobody can predict is worse
/// than no router.
///
/// Hard rules (never overridden):
///  1. No provider configured / no key  -> local.
///  2. Offline                            -> local.
///  3. Private mode on                    -> local, always.
///  4. Turn contains images but the local vision model is not loaded
///     -> cloud, if a vision-capable provider exists. Otherwise refused: no
///     model is ever asked to answer a question it cannot actually receive.
///
/// Soft rules (scored):
///  * Long inputs, code, and explicit "think hard" phrasing push to cloud.
///  * Short, conversational, or personal-data turns stay local.
///  * Battery saver and metered networks push to local.
library;

import 'dart:io';

import '../../core/utils/log.dart';
import '../../domain/models/cloud_provider.dart';

enum RouteTarget { local, cloud, refused }

class RouteDecision {
  final RouteTarget target;
  final CloudProvider? provider;
  final String modelId;

  /// Plain-English reason, shown in the UI. Users should never wonder why a
  /// message went to the network.
  final String reason;

  /// True when the decision was forced by a hard rule.
  final bool forced;

  const RouteDecision({
    required this.target,
    required this.reason,
    this.provider,
    this.modelId = '',
    this.forced = false,
  });

  bool get isCloud => target == RouteTarget.cloud;

  /// True when the turn cannot be served honestly by anything available.
  ///
  /// The caller must surface [reason] and **not** invoke a model. Sending an
  /// image to a text-only model produces a confident answer to a question that
  /// was never actually asked.
  bool get isRefused => target == RouteTarget.refused;

  static const localDefault = RouteDecision(
    target: RouteTarget.local,
    reason: 'On-device model',
    forced: true,
  );
}

class RoutingConfig {
  /// 'local' | 'cloud' | 'auto'
  final String mode;

  /// When true, never contact the network regardless of mode.
  final bool privateMode;

  /// Prefer local when on a metered connection.
  final bool preferLocalOnMetered;

  /// Turns longer than this (characters) push toward cloud.
  final int longInputThreshold;

  const RoutingConfig({
    this.mode = 'auto',
    this.privateMode = false,
    this.preferLocalOnMetered = true,
    this.longInputThreshold = 1500,
  });
}

/// Build the [RoutingConfig] for a single chat turn from the settings map.
///
/// This is the one place the persisted settings become a routing decision, so
/// both privacy guarantees are enforced together and are unit-testable:
///
///  * **Private mode always wins.** A per-message "cloud once" request cannot
///    flip it, because nothing may leave the device while private mode is on.
///  * **A per-message "cloud once" forces cloud for exactly this turn** by
///    overriding the persisted [mode] locally — it never writes anything back,
///    so the next turn reverts to the user's saved choice.
///
/// Forcing the mode to `cloud` does not, on its own, guarantee a cloud call:
/// [RouterService.decide] still refuses when there is no configured provider,
/// when the device is offline, or when private mode is on.
RoutingConfig routeConfigForTurn({
  required String mode,
  required bool privateMode,
  required bool preferLocalOnMetered,
  bool sendToCloudOnce = false,
}) {
  return RoutingConfig(
    mode: sendToCloudOnce && !privateMode ? 'cloud' : mode,
    privateMode: privateMode,
    preferLocalOnMetered: preferLocalOnMetered,
  );
}

/// Seam for the connectivity probe: when non-null it replaces the real DNS
/// lookup. Production leaves it null; a test sets it to count calls and prove
/// that private mode performs *no* lookup, rather than relying on a negative
/// that a live network could mask.
typedef DnsLookup = Future<List<InternetAddress>> Function(String host);

/// Test-only override for [RouterService.probeConnectivity]'s DNS lookup.
DnsLookup? dnsLookupOverride;

class RouterService {
  RouterService._();

  static RouterService? _instance;
  static RouterService get instance => _instance ??= RouterService._();

  /// Set by the app at startup and whenever connectivity changes.
  bool isOnline = true;
  bool isMetered = false;

  /// When true the router must not make *any* network call — not even the DNS
  /// connectivity probe. Mirrors the persisted `private_mode` setting, and is
  /// set at startup and whenever the user toggles it.
  bool privateMode = false;

  /// Candidates in preference order: (provider, modelId).
  List<({CloudProvider provider, String modelId})> _candidates = const [];

  void setCandidates(List<({CloudProvider provider, String modelId})> list) {
    _candidates = list;
    Log.i('router: ${list.length} cloud candidate(s) configured');
  }

  /// True when at least one cloud provider is configured. On a fresh install
  /// this is false, and [decide] then refuses cloud for every turn.
  bool get hasCloud => _candidates.isNotEmpty;

  /// The best cloud option able to accept an image, if any.
  ({CloudProvider provider, String modelId})? get visionCandidate {
    for (final c in _candidates) {
      final m = c.provider.modelById(c.modelId);
      if (m != null && m.supportsVision) return c;
    }
    return null;
  }

  /// Decide where this turn should run.
  ///
  /// [prompt] is the user's text, [hasImages] whether a picture is attached,
  /// and [localVisionReady] whether the on-device model can actually see.
  RouteDecision decide({
    required String prompt,
    required RoutingConfig config,
    bool hasImages = false,
    bool localVisionReady = false,
    bool localModelReady = false,
  }) {
    // ---- hard rules -------------------------------------------------------

    // Checked FIRST, ahead of every "where should it run" rule below, because a
    // picture nobody can look at is not answerable anywhere.
    //
    // The order is the whole point. With this block placed after the
    // `_candidates.isEmpty` check, a device with no cloud configured returned
    // `local` first, the image was handed to a text model, the plugin discarded
    // it, and a perfectly clear question came back as "I didn't understand your
    // question" — which is exactly the bug this is here to stop.
    if (hasImages && !localVisionReady) {
      // Private mode and offline are absolute: never reach for a cloud model,
      // even to save the turn.
      final v = (config.privateMode || !isOnline) ? null : visionCandidate;
      if (v != null) {
        return RouteDecision(
          target: RouteTarget.cloud,
          provider: v.provider,
          modelId: v.modelId,
          reason: 'Image attached but no on-device vision model is loaded — '
              'using ${v.provider.displayName}',
          forced: true,
        );
      }
      // No vision anywhere. Refuse rather than ask a model that cannot see.
      return const RouteDecision(
        target: RouteTarget.refused,
        reason: 'This message has an image, but no vision model is loaded, so '
            'nothing can actually look at it. Load a vision model in '
            'Settings → Models, then send again.',
        forced: true,
      );
    }

    if (config.privateMode) {
      return const RouteDecision(
        target: RouteTarget.local,
        reason: 'Private mode is on — nothing leaves this device',
        forced: true,
      );
    }

    if (!isOnline) {
      return const RouteDecision(
        target: RouteTarget.local,
        reason: 'Offline — using the on-device model',
        forced: true,
      );
    }

    if (_candidates.isEmpty) {
      return const RouteDecision(
        target: RouteTarget.local,
        reason: 'No cloud model configured — using the on-device model',
        forced: true,
      );
    }

    // ---- explicit user mode ----------------------------------------------
    if (config.mode == 'local') {
      return const RouteDecision(
        target: RouteTarget.local,
        reason: 'Cloud is set to "local only"',
        forced: true,
      );
    }

    if (!localModelReady) {
      final c = _candidates.first;
      return RouteDecision(
        target: RouteTarget.cloud,
        provider: c.provider,
        modelId: c.modelId,
        reason: 'No on-device model loaded — using ${c.provider.displayName}',
        forced: true,
      );
    }

    if (config.mode == 'cloud') {
      final c = _candidates.first;
      return RouteDecision(
        target: RouteTarget.cloud,
        provider: c.provider,
        modelId: c.modelId,
        reason: 'Cloud mode is on — using ${c.provider.displayName}',
        forced: true,
      );
    }

    // ---- auto: score it ---------------------------------------------------
    return _score(prompt, config, hasImages: hasImages);
  }

  RouteDecision _score(
    String prompt,
    RoutingConfig config, {
    bool hasImages = false,
  }) {
    var cloudScore = 0;
    final reasons = <String>[];

    if (prompt.length > config.longInputThreshold) {
      cloudScore += 3;
      reasons.add('long input');
    }

    final lower = prompt.toLowerCase();

    // Things small on-device models are genuinely bad at.
    const hardMarkers = {
      'prove', 'derive', 'algorithm', 'complexity', 'refactor',
      'debug', 'stack trace', 'compile', 'regex', 'sql', 'architecture',
      'step by step', 'think carefully', 'in depth', 'essay',
      'translate', 'summarize this document', 'legal', 'medical',
    };
    for (final m in hardMarkers) {
      if (lower.contains(m)) {
        cloudScore += 2;
        reasons.add('"$m"');
        break;
      }
    }

    // Obvious code is a strong signal: a 0.5B model cannot write it well.
    if (lower.contains('```') || lower.contains('def ') ||
        lower.contains('function ') || lower.contains('class ')) {
      cloudScore += 3;
      reasons.add('code');
    }

    // Long conversation history is easier to justify spending tokens on.
    if (prompt.length > 4000) {
      cloudScore += 2;
      reasons.add('very long context');
    }

    if (hasImages) {
      cloudScore += 1;
      reasons.add('image');
    }

    // Personal-sounding turns belong on-device.
    const privateMarkers = {
      'my password', 'my address', 'my number', 'my bank', 'my account',
      'my messages', 'my contacts', 'my location', 'private', 'secret',
      'diary', 'journal',
    };
    for (final m in privateMarkers) {
      if (lower.contains(m)) {
        cloudScore -= 4;
        reasons.add('personal data');
        break;
      }
    }

    // Terse conversational turns are the on-device model's home turf. This is
    // only a tiebreaker: applying it unconditionally would let it cancel out a
    // genuine signal like a code snippet, which is how "def parse(s): ..."
    // ended up staying local.
    if (cloudScore == 0 && prompt.length < 120) {
      cloudScore -= 1;
    }

    if (config.preferLocalOnMetered && isMetered) {
      cloudScore -= 3;
      reasons.add('metered connection');
    }

    if (cloudScore >= 3) {
      final c = _candidates.first;
      final why = reasons.isEmpty ? 'better suited to a larger model'
                                  : reasons.take(2).join(', ');
      return RouteDecision(
        target: RouteTarget.cloud,
        provider: c.provider,
        modelId: c.modelId,
        reason: 'Sent to ${c.provider.displayName} ($why)',
      );
    }

    return const RouteDecision(
      target: RouteTarget.local,
      reason: 'On-device model — nothing left this device',
    );
  }

  /// Best-effort connectivity probe used to keep [isOnline] honest.
  ///
  /// Uses a DNS lookup rather than an HTTP request so it costs no bandwidth
  /// and leaks no request metadata.
  ///
  /// **Private mode skips it entirely.** A DNS lookup is still a network call,
  /// and private mode promises that nothing leaves the device — so when
  /// [privateMode] is set the probe returns the last known state without
  /// touching the network.
  Future<bool> probeConnectivity() async {
    if (privateMode) {
      Log.d('router: private mode — skipping the connectivity probe');
      return isOnline;
    }
    try {
      const host = 'one.one.one.one';
      final override = dnsLookupOverride;
      final result = override != null
          ? await override(host).timeout(const Duration(seconds: 3))
          : await InternetAddress.lookup(host)
              .timeout(const Duration(seconds: 3));
      isOnline = result.isNotEmpty &&
          result.first.rawAddress.isNotEmpty;
    } catch (_) {
      isOnline = false;
    }
    return isOnline;
  }

  /// Public endpoint presence only — no payload is sent.
  Future<bool> hasWideAreaNetwork() async {
    for (final i in await NetworkInterface.list()) {
      if (i.name.startsWith('wlan') || i.name.startsWith('rmnet')) return true;
    }
    return false;
  }
}
