/// Riverpod providers for state management
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import '../../data/services/llm_service.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/mcp_service.dart';
import '../../data/services/router_service.dart';
import '../../data/services/secure_store.dart';
import '../../data/tools/tool_registry.dart';
import '../../data/tools/tool_permission_store.dart';
import '../../data/database/database_helper.dart';
import '../../domain/agents/agent_orchestrator.dart';
import '../../domain/models/models.dart';

// LLM Service Provider
final llmServiceProvider = Provider<LlmService>((ref) {
  return LlmService.getInstance();
});

// Cloud LLM Service (bring-your-own-key)
final cloudServiceProvider = Provider<CloudService>((ref) {
  return CloudService.instance;
});

// MCP client — extends the tool set beyond the built-in nine
final mcpServiceProvider = Provider<McpService>((ref) {
  return McpService.instance;
});

// Keystore-backed storage for API keys and the database key
final secureStoreProvider = Provider<SecureStore>((ref) {
  return SecureStore.instance;
});

// Local/cloud routing
final routerServiceProvider = Provider<RouterService>((ref) {
  return RouterService.instance;
});

// Embedding Service Provider
final embeddingServiceProvider = Provider<EmbeddingService>((ref) {
  return EmbeddingService.getInstance();
});

// Tool Registry Provider
final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  return ToolRegistry();
});

// Database Helper Provider
final databaseProvider = Provider<DatabaseHelper>((ref) {
  return DatabaseHelper.instance;
});

// Agent Orchestrator Provider
final agentOrchestratorProvider = Provider<AgentOrchestrator>((ref) {
  return AgentOrchestrator();
});

// Speech to Text Provider
final speechToTextProvider = StateNotifierProvider<SpeechNotifier, bool>((ref) {
  return SpeechNotifier();
});

class SpeechNotifier extends StateNotifier<bool> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isAvailable = false;
  final List<String> _words = [];

  SpeechNotifier() : super(false);

  Future<void> init() async {
    _isAvailable = await _speech.initialize(
      onStatus: (status) => debugPrint('Speech status: $status'),
      onError: (error) => debugPrint('Speech error: $error'),
    );
    state = _isAvailable;
  }

  /// Listens and resolves with the recognised text once the user stops
  /// speaking. `listen()` itself returns void, so the result must be captured
  /// through the callback channel (the previous signature never compiled).
  Future<String?> listenOnce({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_isAvailable) return null;
    _words.clear();

    final completer = Completer<String?>();

    await _speech.listen(
      listenFor: timeout,
      pauseFor: const Duration(seconds: 3),
      onResult: (result) {
        if (result.recognizedWords.isNotEmpty) {
          _words
            ..clear()
            ..add(result.recognizedWords);
        }
        if (result.finalResult && !completer.isCompleted) {
          completer.complete(_words.isEmpty ? null : _words.join(' '));
        }
      },
    );

    // Safety net if the engine never fires finalResult.
    return completer.future.timeout(
      timeout + const Duration(seconds: 2),
      onTimeout: () => _words.isEmpty ? null : _words.join(' '),
    );
  }

  Future<void> stopListening() async {
    await _speech.stop();
  }
}

// Text to Speech Provider
final textToSpeechProvider = StateNotifierProvider<TtsNotifier, bool>((ref) {
  return TtsNotifier();
});

class TtsNotifier extends StateNotifier<bool> {
  final FlutterTts _tts = FlutterTts();
  bool _isReady = false;
  
  TtsNotifier() : super(false);
  
  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setPitch(1.0);
    await _tts.setSpeechRate(0.5);
    _isReady = true;
    state = true;
  }
  
  Future<void> speak(String text) async {
    if (!_isReady) return;
    await _tts.speak(text);
  }
  
  Future<void> stop() async {
    await _tts.stop();
  }
}

// Chat Messages Provider
final chatMessagesProvider = StateNotifierProvider<ChatNotifier, List<ChatMessage>>((ref) {
  return ChatNotifier(ref);
});

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  final Ref ref;
  final DatabaseHelper _db = DatabaseHelper.instance;
  
  ChatNotifier(this.ref) : super([]) {
    _loadMessages();
  }
  
  Future<void> _loadMessages() async {
    final messages = await _db.getRecentMessages(limit: 100);
    state = messages.map((m) => ChatMessage.fromMap(m)).toList().reversed.toList();
  }
  
  Future<void> addMessage(ChatMessage message) async {
    await _db.insertMessage(
      id: message.id,
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
    );
    state = [message, ...state];
  }
  
  Future<void> clearChat() async {
    // In production, delete all messages from DB
    state = [];
  }
}

// Tool Permissions Provider
final toolPermissionsProvider = StateNotifierProvider<PermissionsNotifier, Map<String, String>>((ref) {
  return PermissionsNotifier();
});

/// Tool permissions, backed by the single [ToolPermissionStore].
///
/// This used to keep its own hardcoded map and a `_loadPermissions` that read
/// nothing back, so every restart silently reset the user's choices — and the
/// agent consulted a *different* map anyway. There is now one persisted store,
/// and this notifier is only a view onto it.
class PermissionsNotifier extends StateNotifier<Map<String, String>> {
  final ToolPermissionStore _store = ToolPermissionStore();

  PermissionsNotifier() : super({}) {
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    // The registry has to be populated before we can enumerate tools.
    // `registerTools` is idempotent, so calling it here as well as at startup
    // is safe and makes this provider self-sufficient.
    final registry = ToolRegistry()..registerTools();
    await _store.load(registry.tools.keys);
    state = {
      for (final entry in _store.all.entries) entry.key: entry.value.wire,
    };
  }

  Future<void> setPermission(String tool, String permission) async {
    await _store.set(tool, ToolPermission.parse(permission));
    state = Map.from(state)..[tool] = permission;
  }
}

// Activity Log Provider
final activityLogProvider = StateNotifierProvider<ActivityLogNotifier, List<Map<String, dynamic>>>((ref) {
  return ActivityLogNotifier();
});

class ActivityLogNotifier extends StateNotifier<List<Map<String, dynamic>>> {
  final DatabaseHelper _db = DatabaseHelper.instance;
  
  ActivityLogNotifier() : super([]) {
    _loadLog();
  }
  
  Future<void> _loadLog() async {
    state = await _db.getActivityLog(limit: 100);
  }
  
  Future<void> refresh() async {
    await _loadLog();
  }
}

// Settings Provider
final settingsProvider = StateNotifierProvider<SettingsNotifier, Map<String, dynamic>>((ref) {
  return SettingsNotifier();
});

/// The privacy facts a cloud consent step must state.
///
/// Kept in one place so the consent UI, the code that decides whether consent
/// is needed, and any test all describe exactly the same data. If a new kind of
/// payload is added to a cloud request, it must be listed here or the consent
/// text becomes a lie.
class CloudPrivacy {
  CloudPrivacy._();

  /// What actually leaves the device when a turn is sent to a cloud provider.
  static const List<String> leavesDevice = [
    'the text of your prompt',
    'your recent conversation history',
    'the text of any attached document',
    'any images you attach',
  ];

  /// Plain-English body for the opt-in dialog naming the destination provider.
  static String consentBody(String providerDisplayName) {
    final items = leavesDevice.map((e) => '  \u2022  $e').join('\n');
    return 'If you turn cloud on, the following will be sent over the '
        'internet to $providerDisplayName:\n\n$items\n\n'
        'Once sent, it is handled under that provider\'s own privacy policy, '
        'not this app\'s. Nothing is sent until you agree, the on-device model '
        'stays the default, and you can withdraw this at any time.';
  }
}

/// Whether the stored consent already covers [providerId].
///
/// Consent is bound to a specific destination: switching the active provider
/// makes this return false again, which is what forces the opt-in step to be
/// shown a second time. Consent is *not* inherited by a new provider.
bool cloudConsentGranted(Map<String, dynamic> settings, String? providerId) {
  if (providerId == null || providerId.isEmpty) return false;
  final consented = settings['cloud_consent_provider'];
  return consented is String && consented == providerId;
}

/// One-shot "send the next message to the cloud, just this once" flag.
///
/// This is the per-message affordance. It is deliberately *state* rather than a
/// setting: it applies to exactly one outgoing turn and is consumed as that
/// turn is sent, so a single tap can never leak more than one message. It never
/// overrides private mode — see [routeConfigForTurn].
final cloudOnceProvider =
    StateNotifierProvider<CloudOnceNotifier, bool>((ref) {
  return CloudOnceNotifier();
});

class CloudOnceNotifier extends StateNotifier<bool> {
  CloudOnceNotifier() : super(false);

  /// Arm the override for the next message.
  void armForNextMessage() => state = true;

  /// Read and clear the flag. Returns true when a one-shot cloud send was armed.
  bool consume() {
    final armed = state;
    if (armed) state = false;
    return armed;
  }
}

/// Enforces that a destructive action is confirmed twice.
///
/// A single dialog with one confirm button is one step. This gate refuses to
/// report completion unless the caller first recorded the first step, so "Erase
/// all data" cannot be triggered by a stray tap or a mis-wired single dialog —
/// the second confirmation only counts if the first genuinely happened.
class TwoStepConfirm {
  bool _firstDone = false;

  /// Whether the first confirmation has been given and not yet consumed.
  bool get awaitingSecond => _firstDone;

  /// Record the first confirmation.
  void confirmFirst() => _firstDone = true;

  /// Record the second confirmation. Returns true only when the first step had
  /// already been taken; always clears the gate afterwards so it cannot be
  /// reused for a second erase without going through both steps again.
  bool confirmSecond() {
    final ok = _firstDone;
    _firstDone = false;
    return ok;
  }

  /// Abandon the flow (e.g. the user cancelled at the second dialog).
  void cancel() => _firstDone = false;
}

class SettingsNotifier extends StateNotifier<Map<String, dynamic>> {

  /// The conservative first-run defaults. Extracted so "Erase all data" can
  /// restore exactly this state without a second copy of the map drifting from
  /// the constructor's.
  static Map<String, dynamic> _defaults() => {
    'context_size': 2048,
    'personality': 'professional',
    'tts_enabled': true,
    'voice_enabled': true,
    'model_path': null,

    // Cloud / privacy. Defaults are the conservative ones: auto routing,
    // private mode off, and metered connections biased to the local model.
    'cloud_mode': 'auto',
    'private_mode': false,
    'prefer_local_metered': true,
    'active_cloud_provider': null,
    'active_cloud_model': null,

    // Cloud consent, bound to a specific provider id. Null means "not granted
    // for anything", so a fresh install never routes to the cloud without the
    // opt-in step.
    'cloud_consent_provider': null,

    // Security
    'biometric_lock': false,

    // Compute backend: auto | gpu | cpu. 'auto' follows GpuService, which
    // stays on the CPU for midrange Mali parts where the GPU usually loses.
    'gpu_offload': 'auto',

    // Number of CPU threads for inference (1-4). The default of 4 is a safe
    // starting point for most phones; reduce to 2 or 1 if you experience
    // thermal throttling or OOM on low-end devices.
    'cpu_threads': 4,

    // First-run
    'onboarding_done': false,
  };

  final DatabaseHelper _db = DatabaseHelper.instance;

  SettingsNotifier() : super(_defaults()) {
    _loadSettings();
  }
  
  Future<void> _loadSettings() async {
    final contextSize = await _db.getPreference('context_size');
    if (contextSize != null) {
      state = Map.from(state)..['context_size'] = int.parse(contextSize);
    }
    
    final personality = await _db.getPreference('personality');
    if (personality != null) {
      state = Map.from(state)..['personality'] = personality;
    }
    
    final ttsEnabled = await _db.getPreference('tts_enabled');
    if (ttsEnabled != null) {
      state = Map.from(state)..['tts_enabled'] = ttsEnabled == 'true';
    }

    // Booleans need explicit string parsing; `as bool` would throw on 'true'.
    for (final key in [
      'private_mode',
      'prefer_local_metered',
      'biometric_lock',
      'voice_enabled',
      'onboarding_done',
    ]) {
      final raw = await _db.getPreference(key);
      if (raw != null) {
        state = Map.from(state)..[key] = raw == 'true';
      }
    }

    for (final key in [
      'cloud_mode',
      'active_cloud_provider',
      'active_cloud_model',
      'model_path',
      'gpu_offload',
      'cpu_threads',
      'cloud_consent_provider',
    ]) {
      final raw = await _db.getPreference(key);
      if (raw != null && raw.isNotEmpty) {
        state = Map.from(state)..[key] = raw;
      }
    }

    // Mirror private mode onto the router *before* any probe runs, so the
    // probe is correctly skipped when private mode is on (a DNS lookup is a
    // network call, and private mode promises none).
    RouterService.instance.privateMode = state['private_mode'] as bool? ?? false;

    // Keep the router's view of connectivity fresh.
    await RouterService.instance.probeConnectivity();
  }

  Future<void> updateSetting(String key, dynamic value) async {
    state = Map.from(state)..[key] = value;

    // Private mode is also a router concern: flipping it must take effect
    // immediately so the connectivity probe starts/stops respecting it.
    if (key == 'private_mode') {
      RouterService.instance.privateMode = value == true;
    }

    if (value is String) {
      await _db.savePreference(key, value);
    } else if (value is int) {
      await _db.savePreference(key, value.toString());
    } else if (value is bool) {
      await _db.savePreference(key, value.toString());
    }
  }

  /// Record that the user consented to sending data to [providerId]. Persisted,
  /// so the opt-in step is shown once per destination rather than on every
  /// launch. Consent is bound to that id: if the destination provider later
  /// changes, [cloudConsentGranted] no longer matches and the step is shown
  /// again.
  Future<void> grantCloudConsent(String providerId) =>
      updateSetting('cloud_consent_provider', providerId);

  /// Withdraw consent for the current destination. An empty value is treated as
  /// "no consent" on the next load, so the opt-in step is shown again.
  Future<void> revokeCloudConsent() =>
      updateSetting('cloud_consent_provider', '');

  /// Restore the conservative first-run defaults after a full erase, so the app
  /// presents a clean first-run state without a relaunch.
  Future<void> resetToDefaults() async {
    state = _defaults();
    RouterService.instance.privateMode = false;
  }
}
