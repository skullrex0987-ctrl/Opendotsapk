/// Cloud LLM client — bring-your-own-key, over plain `http`.
///
/// One small client per wire format rather than an SDK per vendor: the app
/// already ships three native runtimes, and pulling in several vendor SDKs
/// (plus their transitive deps) to make three HTTP calls is not a good trade.
///
/// Everything here streams. Tokens are yielded as they arrive so the UI is
/// identical whether the answer comes from a local GGUF or the network.
///
/// Privacy contract, enforced by the callers:
///  * Nothing is sent unless a key is configured for that provider AND the
///    router picked cloud for this turn.
///  * Keys are read from [SecureStore] at request time and never logged.
///  * `Log` records the provider and model, never the prompt or the key.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/utils/log.dart';
import '../../domain/models/cloud_provider.dart';
import 'secure_store.dart';

class CloudException implements Exception {
  final String message;
  final int? statusCode;

  const CloudException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

class CloudTurn {
  final String modelId;
  final List<Map<String, String>> messages;
  final double temperature;
  final int maxTokens;
  final List<String> imageBase64;
  final List<Map<String, dynamic>> tools;

  const CloudTurn({
    required this.modelId,
    required this.messages,
    this.temperature = 0.7,
    this.maxTokens = 1024,
    this.imageBase64 = const [],
    this.tools = const [],
  });
}

class CloudUsage {
  final int promptTokens;
  final int completionTokens;

  /// Approximate USD, derived from catalog prices. Displayed, never billed.
  final double estimatedCostUsd;

  const CloudUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.estimatedCostUsd = 0,
  });

  static const empty = CloudUsage();
}

class CloudService {
  CloudService._();

  static CloudService? _instance;
  static CloudService get instance => _instance ??= CloudService._();

  final http.Client _client = http.Client();

  /// Cumulative estimate for the session, shown in Settings.
  double sessionCostUsd = 0;
  int sessionPromptTokens = 0;
  int sessionCompletionTokens = 0;

  void resetSessionUsage() {
    sessionCostUsd = 0;
    sessionPromptTokens = 0;
    sessionCompletionTokens = 0;
  }

  // ------------------------------------------------------------------ public

  /// Stream a completion. Throws [CloudException] with a readable message.
  ///
  /// [onUsage] fires once at the end when the provider reports token counts.
  Stream<String> stream({
    required CloudProvider provider,
    required CloudTurn turn,
    void Function(CloudUsage)? onUsage,
  }) async* {
    final key = await SecureStore.instance.apiKey(provider.id);
    final config = await SecureStore.instance.providerConfig(provider.id);
    final baseUrl = (config['baseUrl']?.isNotEmpty ?? false)
        ? config['baseUrl']!
        : provider.defaultBaseUrl;

    if ((key == null || key.isEmpty) &&
        !CloudCatalog.keyOptional.contains(provider.id)) {
      throw CloudException(
        'No API key saved for ${provider.displayName}. '
        'Add one in Settings → Cloud Models.',
      );
    }

    Log.i(
      'cloud: ${provider.id} / ${turn.modelId} '
      '(${turn.messages.length} msgs, ${turn.imageBase64.length} images)',
    );

    switch (provider.wireFormat) {
      case CloudWireFormat.openAiCompatible:
        yield* _streamOpenAi(
          provider: provider,
          baseUrl: baseUrl,
          apiKey: key ?? '',
          turn: turn,
          onUsage: onUsage,
        );
      case CloudWireFormat.anthropic:
        yield* _streamAnthropic(
          provider: provider,
          baseUrl: baseUrl,
          apiKey: key ?? '',
          turn: turn,
          onUsage: onUsage,
        );
      case CloudWireFormat.gemini:
        yield* _streamGemini(
          provider: provider,
          baseUrl: baseUrl,
          apiKey: key ?? '',
          turn: turn,
          onUsage: onUsage,
        );
    }
  }

  /// One-shot completion, used by the planner and by connection tests.
  Future<String> complete({
    required CloudProvider provider,
    required CloudTurn turn,
  }) async {
    final buf = StringBuffer();
    await for (final t in stream(provider: provider, turn: turn)) {
      buf.write(t);
    }
    return buf.toString();
  }

  /// Cheap "is this key valid" probe — one tiny request, minimal tokens.
  Future<String> testConnection({
    required CloudProvider provider,
    required String modelId,
  }) async {
    final text = await complete(
      provider: provider,
      turn: CloudTurn(
        modelId: modelId,
        messages: const [
          {'role': 'user', 'content': 'Reply with the single word: ok'},
        ],
        maxTokens: 8,
        temperature: 0,
      ),
    );
    return text.trim();
  }

  void dispose() => _client.close();

  // ------------------------------------------------------- wire: OpenAI-ish

  Stream<String> _streamOpenAi({
    required CloudProvider provider,
    required String baseUrl,
    required String apiKey,
    required CloudTurn turn,
    void Function(CloudUsage)? onUsage,
  }) async* {
    final messages = <Map<String, dynamic>>[];

    for (var i = 0; i < turn.messages.length; i++) {
      final m = turn.messages[i];
      final isLast = i == turn.messages.length - 1;

      // Attach images to the final user message as content parts.
      if (isLast && turn.imageBase64.isNotEmpty && m['role'] == 'user') {
        final parts = <Map<String, dynamic>>[
          {'type': 'text', 'text': m['content'] ?? ''},
          for (final b64 in turn.imageBase64)
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$b64'},
            },
        ];
        messages.add({'role': 'user', 'content': parts});
      } else {
        messages.add({'role': m['role'], 'content': m['content']});
      }
    }

    final body = <String, dynamic>{
      'model': turn.modelId,
      'messages': messages,
      'temperature': turn.temperature,
      'max_tokens': turn.maxTokens,
      'stream': true,
      if (turn.tools.isNotEmpty) 'tools': turn.tools,
    };

    final headers = {
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };

    final uri = Uri.parse('${_trim(baseUrl)}/chat/completions');
    final promptChars = turn.messages.fold<int>(
      0,
      (a, m) => a + (m['content']?.length ?? 0),
    );

    await for (final line in _sseLines(uri, headers, body)) {
      if (line == '[DONE]') break;
      final json = _tryJson(line);
      if (json == null) continue;

      final choice = _firstChoice(json);
      final delta = choice?['delta'];

      final content = delta is Map ? delta['content'] : null;
      if (content is String && content.isNotEmpty) yield content;

      final usage = json['usage'];
      if (usage is Map) {
        _recordUsage(
          provider,
          turn.modelId,
          promptChars,
          usage['prompt_tokens'] as int? ?? 0,
          usage['completion_tokens'] as int? ?? 0,
          onUsage,
        );
      }
    }
  }

  // -------------------------------------------------------- wire: Anthropic

  Stream<String> _streamAnthropic({
    required CloudProvider provider,
    required String baseUrl,
    required String apiKey,
    required CloudTurn turn,
    void Function(CloudUsage)? onUsage,
  }) async* {
    // Anthropic wants the system prompt as a top-level field, not a message.
    String? system;
    final messages = <Map<String, dynamic>>[];

    for (var i = 0; i < turn.messages.length; i++) {
      final m = turn.messages[i];
      final role = m['role'];
      final text = m['content'] ?? '';

      if (role == 'system') {
        system = system == null ? text : '$system\n\n$text';
        continue;
      }

      final isLast = i == turn.messages.length - 1;
      if (isLast && turn.imageBase64.isNotEmpty && role == 'user') {
        messages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
            for (final b64 in turn.imageBase64)
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/jpeg',
                  'data': b64,
                },
              },
          ],
        });
      } else {
        // Anthropic rejects consecutive same-role messages; merge defensively.
        if (messages.isNotEmpty && messages.last['role'] == role) {
          final prev = messages.last;
          prev['content'] = '${prev['content']}\n\n$text';
        } else {
          messages.add({'role': role, 'content': text});
        }
      }
    }

    final body = <String, dynamic>{
      'model': turn.modelId,
      'messages': messages,
      'max_tokens': turn.maxTokens,
      'temperature': turn.temperature,
      'stream': true,
      if (system != null) 'system': system,
    };

    final headers = {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    };

    final uri = Uri.parse('${_trim(baseUrl)}/messages');
    final promptChars = turn.messages.fold<int>(
      0,
      (a, m) => a + (m['content']?.length ?? 0),
    );

    await for (final line in _sseLines(uri, headers, body)) {
      final json = _tryJson(line);
      if (json == null) continue;

      switch (json['type']) {
        case 'content_block_delta':
          final d = json['delta'];
          final t = d is Map ? d['text'] : null;
          if (t is String && t.isNotEmpty) yield t;
        case 'message_delta':
          final u = json['usage'];
          if (u is Map) {
            _recordUsage(
              provider,
              turn.modelId,
              promptChars,
              u['input_tokens'] as int? ?? 0,
              u['output_tokens'] as int? ?? 0,
              onUsage,
            );
          }
        case 'error':
          final err = json['error'];
          throw CloudException(
            '${provider.displayName}: ${err is Map ? err['message'] : err}',
          );
      }
    }
  }

  // ----------------------------------------------------------- wire: Gemini

  Stream<String> _streamGemini({
    required CloudProvider provider,
    required String baseUrl,
    required String apiKey,
    required CloudTurn turn,
    void Function(CloudUsage)? onUsage,
  }) async* {
    final contents = <Map<String, dynamic>>[];
    String? systemText;

    for (var i = 0; i < turn.messages.length; i++) {
      final m = turn.messages[i];
      final role = m['role'] == 'assistant' ? 'model' : 'user';
      final text = m['content'] ?? '';

      if (m['role'] == 'system') {
        systemText = systemText == null ? text : '$systemText\n\n$text';
        continue;
      }

      final parts = <Map<String, dynamic>>[
        {'text': text},
      ];

      final isLast = i == turn.messages.length - 1;
      if (isLast && turn.imageBase64.isNotEmpty && role == 'user') {
        for (final b64 in turn.imageBase64) {
          parts.add({
            'inline_data': {'mime_type': 'image/jpeg', 'data': b64},
          });
        }
      }

      contents.add({'role': role, 'parts': parts});
    }

    final body = <String, dynamic>{
      'contents': contents,
      'generationConfig': {
        'temperature': turn.temperature,
        'maxOutputTokens': turn.maxTokens,
      },
      if (systemText != null)
        'systemInstruction': {
          'parts': [
            {'text': systemText},
          ],
        },
    };

    // The key goes in a header, never the query string. A key in a URL leaks
    // into server logs, proxy logs and crash reports — and any error message
    // that echoes the request URL would print it straight into the chat.
    final uri = Uri.parse(
      '${_trim(baseUrl)}/models/${turn.modelId}:streamGenerateContent?alt=sse',
    );

    final request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json'
      ..headers['x-goog-api-key'] = apiKey
      ..body = jsonEncode(body);

    final promptChars = turn.messages.fold<int>(
      0,
      (a, m) => a + (m['content']?.length ?? 0),
    );

    await for (final line in _sseFromRequest(request)) {
      final json = _tryJson(line);
      if (json == null) continue;

      final candidates = json['candidates'];
      if (candidates is List && candidates.isNotEmpty) {
        final parts = (candidates.first['content'] as Map?)?['parts'];
        if (parts is List) {
          for (final p in parts) {
            final t = (p as Map)['text'];
            if (t is String && t.isNotEmpty) yield t;
          }
        }
      }

      final um = json['usageMetadata'];
      if (um is Map) {
        _recordUsage(
          provider,
          turn.modelId,
          promptChars,
          um['promptTokenCount'] as int? ?? 0,
          um['candidatesTokenCount'] as int? ?? 0,
          onUsage,
        );
      }
    }
  }

  // ------------------------------------------------------------- plumbing

  /// Open an SSE stream and yield `data:` payloads.
  Stream<String> _sseLines(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async* {
    final request = http.Request('POST', uri)
      ..headers.addAll(headers)
      ..body = jsonEncode(body);

    final response = await _client.send(request);

    if (response.statusCode >= 400) {
      final text = await response.stream.bytesToString();
      throw CloudException(
        _explainError(response.statusCode, text),
        statusCode: response.statusCode,
      );
    }

    yield* response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.startsWith('data:'))
        .map((l) => l.substring(5).trim())
        .where((l) => l.isNotEmpty);
  }

  /// How long the provider gets to start responding.
  static const Duration _connectTimeout = Duration(seconds: 15);

  /// How long the stream may go silent once it has started.
  ///
  /// Without these two timeouts a stalled cloud stream hung the UI on
  /// "Thinking…" indefinitely — the same visible symptom as the v1.1.0 local
  /// bug, from an entirely different cause.
  static const Duration _inactivityTimeout = Duration(seconds: 60);

  Stream<String> _sseFromRequest(http.Request request) async* {
    final response = await _client
        .send(request)
        .timeout(
          _connectTimeout,
          onTimeout: () => throw CloudException(
            'The provider did not start responding within '
            '${_connectTimeout.inSeconds}s. Check your connection and try again.',
          ),
        );
    if (response.statusCode >= 400) {
      final text = await response.stream.bytesToString();
      throw CloudException(
        _explainError(response.statusCode, text),
        statusCode: response.statusCode,
      );
    }
    yield* response.stream
        .timeout(
          _inactivityTimeout,
          onTimeout: (sink) => sink.addError(
            CloudException(
              'The stream stalled — no data for '
              '${_inactivityTimeout.inSeconds}s. The reply was cut short.',
            ),
          ),
        )
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((l) => l.startsWith('data:'))
        .map((l) => l.substring(5).trim())
        .where((l) => l.isNotEmpty);
  }

  /// Turn provider errors into something a human can act on.
  static String _explainError(int status, String body) {
    final detail = _extractMessage(body);
    switch (status) {
      case 401:
        return 'Authentication failed — the API key looks wrong or expired. '
            'Check it in Settings → Cloud Models.${detail.isEmpty ? '' : ' ($detail)'}';
      case 402:
        return 'The provider reports insufficient credit.$detail';
      case 403:
        return 'Access denied — this key may not have permission for that model.$detail';
      case 404:
        return 'Model not found — it may have been retired or renamed.$detail';
      case 429:
        return 'Rate limited or out of quota. Wait a moment, or switch to '
            'another model.$detail';
      default:
        if (status >= 500) {
          return 'The provider is having trouble (HTTP $status). '
              'Fall back to the on-device model.$detail';
        }
        return 'Request failed (HTTP $status).$detail';
    }
  }

  static String _extractMessage(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        if (e is Map && e['message'] is String) return ' ${e['message']}';
        if (e is String) return ' $e';
        if (j['message'] is String) return ' ${j['message']}';
      }
    } catch (_) {
      // Not JSON — fall through to a trimmed raw body.
    }
    final t = body.trim();
    if (t.isEmpty) return '';
    return ' ${t.length > 240 ? '${t.substring(0, 240)}…' : t}';
  }

  void _recordUsage(
    CloudProvider provider,
    String modelId,
    int promptChars,
    int promptTokens,
    int completionTokens,
    void Function(CloudUsage)? onUsage,
  ) {
    // Some providers omit usage; estimate from characters rather than showing 0.
    final pt = promptTokens > 0 ? promptTokens : (promptChars / 4).ceil();
    final model = provider.modelById(modelId);

    var cost = 0.0;
    if (model != null) {
      cost =
          (pt / 1e6) * model.inputPricePerM +
          (completionTokens / 1e6) * model.outputPricePerM;
    }

    sessionPromptTokens += pt;
    sessionCompletionTokens += completionTokens;
    sessionCostUsd += cost;

    onUsage?.call(
      CloudUsage(
        promptTokens: pt,
        completionTokens: completionTokens,
        estimatedCostUsd: cost,
      ),
    );
  }

  static Map<String, dynamic>? _tryJson(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _firstChoice(Map<String, dynamic> json) {
    final c = json['choices'];
    if (c is List && c.isNotEmpty && c.first is Map) {
      return Map<String, dynamic>.from(c.first as Map);
    }
    return null;
  }

  static String _trim(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;
}
