/// Pulling a JSON object out of model output.
///
/// Models do not reliably return bare JSON. In practice a local 0.5B model
/// answers a "reply with ONLY JSON" instruction with any of:
///
/// ```json
/// {"plan": [...]}
/// ```
///
/// or
///
/// Sure! Here is the plan:
/// {"plan": [...]}
///
/// Calling `jsonDecode` on that raw text throws, and the previous code caught
/// the throw and substituted a canned step — so the agent quietly stopped
/// planning while still appearing to work. Tolerating the wrapper is what makes
/// the planner's output actually usable.
library;

import 'dart:convert';

/// Extracts the first JSON object found in [raw], or null if there is none.
///
/// Handles a fenced code block, leading prose, and trailing prose.
Map<String, dynamic>? extractJsonObject(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;

  // Prefer the contents of a fenced block when one is present, since a model
  // that fences its JSON may also print braces in the surrounding prose.
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
  final fenced = fence.firstMatch(text);
  if (fenced != null) text = fenced.group(1)!.trim();

  final direct = _tryDecodeObject(text);
  if (direct != null) return direct;

  // Fall back to the widest brace span in the remaining text.
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start >= 0 && end > start) {
    return _tryDecodeObject(text.substring(start, end + 1));
  }

  return null;
}

Map<String, dynamic>? _tryDecodeObject(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}
