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
///     -> cloud, if a vision-capable provider exists. Otherwise local and we
///     say so rather than pretending.
///
/// Soft rules (scored):
///  * Long inputs, code, and explicit "think hard" phrasing push to cloud.
///  * Short, conversational, or personal-data turns stay local.
///  * Battery saver and metered networks push to local.
library;

import 'dart:io';

import '../../core/utils/log.dart';
import '../../domain/models/cloud_provider.dart';

enum RouteTarget { local, cloud }

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

  static const localDefault = RouteDecision(
    target: RouteTarget.local,
    reason: 'On-device model',
    forced: true,
  );
}

class RouterConfig {
  /// 'local' | 'cloud' | 'auto'
  final String mode;

  /// When true, never contact the network regardless of mode.
  final bool privateMode;

  /// Prefer local when on a metered connection.
  final bool preferLocalOnMetered;

  /// Turns longer than this (characters) push toward cloud.
  final int longInputThreshold;

  const RouterConfig({
    this.mode = 'auto',
    this.privateMode = false,
    this.preferLocalOnMetered = true,
    this.longInputThreshold = 1500,
  });
}

class RouterService {
  RouterService._();

  static RouterService? _instance;
  static RouterService get instance => _instance ??= RouterService._();

  /// Set by the app at startup and whenever connectivity changes.
  bool isOnline = true;
  bool isMetered = false;

  /// Candidates in preference order: (provider, modelId).
  List<({CloudProvider provider, String modelId})> _candidates = const [];

  void setCandidates(List<({CloudProvider provider, String modelId})> list) {
    _candidates = list;
    Log.i('router: ${list.length} cloud candidate(s) configured');
  }

  bool get hasCloud =>
      !_candidates.isEmpty && !(_candidates.isEmpty);

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
    required RouterConfig config,
    bool hasImages = false,
    bool localVisionReady = false,
    bool localModelReady = false,
  }) {
    // ---- hard rules -------------------------------------------------------
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

    if (hasImages && !localVisionReady) {
      final v = visionCandidate;
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
      // No vision anywhere: be explicit instead of silently dropping the image.
      return const RouteDecision(
        target: RouteTarget.local,
        reason: 'Image attached, but no vision model is available',
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
    RouterConfig config, {
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
  Future<bool> probeConnectivity() async {
    try {
      final result = await InternetAddress.lookup('one.one.one.one')
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
