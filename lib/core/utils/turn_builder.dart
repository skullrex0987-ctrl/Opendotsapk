/// Choosing which conversation history to send to a model.
///
/// This exists because the previous selection was wrong in three ways at once,
/// and all three are the kind of bug that looks fine until you read the code:
///
/// 1. It used `history.take(10)`. `chatMessagesProvider` is chronological
///    (oldest first), so `take` selected the **ten oldest** messages — the
///    model was given the beginning of the conversation and nothing recent.
/// 2. The current user message had already been appended to that provider
///    before this ran, and the prompt then appended it again, so the question
///    appeared twice.
/// 3. There was no budget. `nCtx` is 2048 and attached documents can add 4000
///    characters each, so the transcript could push the actual question out of
///    the context window entirely.
///
/// Kept dependency-free so it can be unit-tested without a widget, a database
/// or a model.
library;

/// One message to send, in the shape a chat template expects.
class Turn {
  /// 'system', 'user' or 'assistant'.
  final String role;
  final String content;

  const Turn(this.role, this.content);

  @override
  String toString() => '$role: $content';
}

/// Conservative token estimate.
///
/// ~4 characters per token is the usual rule of thumb for English. It is
/// deliberately pessimistic: over-estimating drops a turn we could have kept,
/// under-estimating silently truncates the question. Dropping a turn is
/// recoverable; a truncated question is not.
int estimateTokens(String text) => (text.length / 4).ceil();

/// Selects the most recent history that fits [tokenBudget].
///
/// [history] must be chronological (oldest first), matching how the provider
/// stores it. The result is returned chronological, and the **newest** turns are
/// the ones kept — the reverse of the old behaviour.
///
/// [systemPrompt] is always included and charged against the budget: losing the
/// personality or the tool instructions is worse than losing an old greeting.
///
/// The final turn in [history] is always kept if it is a user turn, even if it
/// exceeds the budget on its own, because a prompt with no question in it is
/// useless. When that happens the caller finds out via [TurnSelection.truncated].
class TurnSelection {
  final List<Turn> turns;
  final int estimatedTokens;
  final bool truncated;

  const TurnSelection({
    required this.turns,
    required this.estimatedTokens,
    required this.truncated,
  });
}

TurnSelection buildRecentTurns({
  required List<Turn> history,
  required int tokenBudget,
  String? systemPrompt,
  int reserveForResponse = 0,
}) {
  final usesSystem = systemPrompt != null && systemPrompt.trim().isNotEmpty;
  var remaining = tokenBudget - reserveForResponse;

  final systemTokens = usesSystem ? estimateTokens(systemPrompt) : 0;
  remaining -= systemTokens;

  // Walk backwards from the newest turn, keeping what fits.
  final kept = <Turn>[];
  var used = systemTokens;
  var truncated = false;

  for (var i = history.length - 1; i >= 0; i--) {
    final turn = history[i];
    final cost = estimateTokens(turn.content) + _roleOverhead;

    if (cost > remaining) {
      // The newest user turn is the question itself; never drop it.
      final isQuestion = i == history.length - 1 && turn.role == 'user';
      if (isQuestion && kept.isEmpty) {
        kept.add(turn);
        used += cost;
        truncated = true;
        remaining -= cost;
        continue;
      }
      truncated = true;
      break;
    }

    kept.add(turn);
    used += cost;
    remaining -= cost;
  }

  // `kept` was built newest-first; a chat template needs oldest-first.
  final ordered = kept.reversed.toList(growable: false);

  final turns = <Turn>[
    if (usesSystem) Turn('system', systemPrompt),
    ...ordered,
  ];

  return TurnSelection(
    turns: turns,
    estimatedTokens: used,
    truncated: truncated,
  );
}

/// Per-message overhead in a chat template (role markers, delimiters).
const int _roleOverhead = 4;
