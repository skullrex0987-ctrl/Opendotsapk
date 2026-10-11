/// Tool definitions and execution.
///
/// Two rules govern this file, both learned the hard way:
///
/// 1. **A tool may only report [ToolStatus.success] if the operation actually
///    happened.** Seven tools here used to return `{"status":"success"}` while
///    doing nothing, which meant the model would tell the user "your SMS has
///    been sent" when no message existed. Anything not genuinely implemented
///    returns [ToolStatus.unsupported] and is hidden from the model by
///    [toolsForModel], so it is never offered in the first place.
///
/// 2. **Prefer a system Intent that shows the OS confirmation UI over a silent
///    privileged API.** Composing an SMS in the user's own messaging app, or
///    handing an alarm to the clock app, means the user sees exactly what will
///    happen and confirms it themselves. Those tools therefore return
///    [ToolStatus.requiresUserAction] — not success — because at the moment we
///    return, nothing has happened yet.
library;

import 'dart:convert';
import 'dart:io';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import '../../domain/models/tool_result.dart';
import '../services/llm_service.dart';

class ToolRegistry {
  static final ToolRegistry _instance = ToolRegistry._internal();
  factory ToolRegistry() => _instance;
  ToolRegistry._internal();

  final Map<String, ToolDefinition> _tools = {};

  /// Registers every tool definition.
  ///
  /// Call once at startup. Until this runs, [tools] is empty — it previously
  /// never ran at all, so the registry was permanently empty and the agent
  /// silently had no tools.
  void registerTools() {
    void add(ToolDefinition def) => _tools[def.name] = def;

    add(ToolDefinition(
      name: 'send_sms',
      description: 'Compose an SMS to a recipient in the messaging app. The '
          'user must tap send; this does not send anything by itself.',
      parameters: {
        'recipient': {'type': 'string', 'description': 'Phone number'},
        'message': {'type': 'string', 'description': 'Message content'},
      },
      required: ['recipient', 'message'],
      implemented: false,
      unimplementedReason: 'Opens the system SMS composer; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'create_calendar_event',
      description: 'Create a calendar event.',
      parameters: {
        'title': {'type': 'string', 'description': 'Event title'},
        'start_time': {'type': 'string', 'description': 'Start time (ISO8601)'},
        'end_time': {'type': 'string', 'description': 'End time (ISO8601)'},
        'location': {'type': 'string', 'description': 'Event location'},
      },
      required: ['title', 'start_time'],
      implemented: false,
      unimplementedReason: 'Needs a calendar insert Intent; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'add_contact',
      description: 'Add a new contact.',
      parameters: {
        'name': {'type': 'string', 'description': 'Contact name'},
        'phone': {'type': 'string', 'description': 'Phone number'},
        'email': {'type': 'string', 'description': 'Email'},
      },
      required: ['name'],
      implemented: false,
      unimplementedReason: 'Needs a contacts insert Intent; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'set_alarm',
      description: 'Set an alarm.',
      parameters: {
        'time': {'type': 'string', 'description': 'Alarm time (ISO8601)'},
        'label': {'type': 'string', 'description': 'Alarm label'},
      },
      required: ['time'],
      implemented: false,
      unimplementedReason: 'Needs the AlarmClock Intent; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'open_app',
      description: 'Open an app by package name.',
      parameters: {
        'package_name': {'type': 'string', 'description': 'App package name'},
      },
      required: ['package_name'],
      implemented: false,
      unimplementedReason: 'Needs a launch Intent; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'web_search',
      description: 'Search the web with DuckDuckGo.',
      parameters: {
        'query': {'type': 'string', 'description': 'Search query'},
      },
      required: ['query'],
      implemented: true,
    ));

    add(ToolDefinition(
      name: 'get_location',
      description: 'Get the device current location.',
      parameters: {},
      required: const [],
      implemented: true,
    ));

    add(ToolDefinition(
      name: 'create_note',
      description: 'Save a note on the device.',
      parameters: {
        'title': {'type': 'string', 'description': 'Note title'},
        'content': {'type': 'string', 'description': 'Note content'},
      },
      required: ['title', 'content'],
      implemented: false,
      unimplementedReason: 'Needs the notes table; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'read_notes',
      description: 'Read notes matching a query.',
      parameters: {
        'query': {'type': 'string', 'description': 'Search query'},
      },
      required: const [],
      implemented: false,
      unimplementedReason: 'Needs the notes table; not yet wired.',
    ));

    add(ToolDefinition(
      name: 'analyze_image',
      description: 'Look at a picture on the device with the local vision '
          'model (Moondream2). Needs a downloaded vision model.',
      parameters: {
        'path': {'type': 'string', 'description': 'Absolute path to the image'},
        'question': {'type': 'string', 'description': 'What to ask'},
      },
      required: ['path'],
      implemented: true,
    ));
  }

  /// Every registered definition, implemented or not.
  Map<String, ToolDefinition> get tools => Map.unmodifiable(_tools);

  /// The definitions the model is allowed to see.
  ///
  /// Hiding unimplemented tools is the point: a tool the model can call but
  /// that cannot work produces a confident lie in the final answer.
  List<ToolDefinition> get toolsForModel =>
      _tools.values.where((t) => t.implemented).toList(growable: false);

  bool isImplemented(String toolName) => _tools[toolName]?.implemented ?? false;

  /// Executes a tool.
  ///
  /// [permission] is no longer accepted here — permission is the caller's
  /// decision, enforced by the orchestrator with a real user prompt. A tool
  /// that takes a permission argument it never reads is worse than one that
  /// takes none, because it looks safe.
  Future<ToolResult> executeTool({
    required String toolName,
    required Map<String, dynamic> params,
  }) async {
    final def = _tools[toolName];
    if (def == null) {
      return ToolResult.failed('Unknown tool: $toolName');
    }
    if (!def.implemented) {
      return ToolResult.unsupported(
        '${def.unimplementedReason ?? 'Not implemented on this build.'} '
        'The tool was not run.',
      );
    }

    switch (toolName) {
      case 'web_search':
        return _executeWebSearch(params);
      case 'get_location':
        return _executeGetLocation(params);
      case 'analyze_image':
        return _executeAnalyzeImage(params);
      default:
        return ToolResult.unsupported('No implementation for "$toolName".');
    }
  }

  Future<ToolResult> _executeWebSearch(Map<String, dynamic> params) async {
    final query = params['query'] as String?;
    if (query == null || query.trim().isEmpty) {
      return ToolResult.failed('web_search requires a non-empty "query".');
    }

    try {
      final response = await http
          .get(Uri.parse(
            'https://lite.duckduckgo.com/lite/?q=${Uri.encodeComponent(query)}',
          ))
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        return ToolResult.failed('Search returned HTTP ${response.statusCode}.');
      }

      final results = _parseDuckDuckGoResults(response.body);
      if (results.isEmpty) {
        // The parser targets a specific markup shape. When the page changes we
        // get zero results, and reporting that as an empty-but-successful search
        // let the model answer as if it had searched. Say so instead.
        return ToolResult.unsupported(
          'Could not read any results from the search page — the response '
          'format may have changed. No results were found.',
        );
      }

      return ToolResult.success(
        'Found ${results.length} result(s).',
        data: {'query': query, 'results': results.take(3).toList()},
      );
    } catch (e) {
      return ToolResult.failed('Search failed: $e');
    }
  }

  Future<ToolResult> _executeGetLocation(Map<String, dynamic> params) async {
    final granted = await Permission.location.request().isGranted;
    if (!granted) {
      return ToolResult.requiresPermission(
        'Location permission was not granted, so the location is unknown.',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      return ToolResult.success(
        'Location acquired.',
        data: {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': position.timestamp.toIso8601String(),
        },
      );
    } catch (e) {
      return ToolResult.failed('Failed to get location: $e');
    }
  }

  /// Run the local vision model over an image already on the device.
  ///
  /// Unlike the stubs above this one is fully implemented — the heavy lifting is
  /// llama.cpp's mtmd path, reached through `LlmService`. It fails loudly rather
  /// than inventing an answer, because a fabricated description of a photo is
  /// worse than no description.
  Future<ToolResult> _executeAnalyzeImage(Map<String, dynamic> params) async {
    final path = params['path'] as String?;
    if (path == null || path.isEmpty) {
      return ToolResult.failed('analyze_image requires a "path" parameter.');
    }

    final file = File(path);
    if (!await file.exists()) {
      return ToolResult.failed('Image not found: $path');
    }

    final llm = LlmService.getInstance();
    if (!llm.isLoaded) {
      return ToolResult.unsupported(
        'No model is loaded. Download one in Settings → Models first.',
      );
    }
    if (!llm.isVisionLoaded) {
      return ToolResult.unsupported(
        'No vision model is loaded. Download Moondream2 in Settings → Models '
        'and select it as the vision model.',
      );
    }

    final question = (params['question'] as String?)?.trim();
    try {
      final answer = await llm.describeImage(
        path,
        instruction: (question == null || question.isEmpty)
            ? 'Describe this image in detail.'
            : question,
      );
      return ToolResult.success(answer, data: {'result': answer});
    } catch (e) {
      return ToolResult.failed('Vision inference failed: $e');
    }
  }

  List<String> _parseDuckDuckGoResults(String html) {
    final results = <String>[];
    final lines = html.split('\n');

    for (final line in lines) {
      if (line.contains('class="result__a"') || line.contains('result__title')) {
        final start = line.indexOf('>') + 1;
        final end = line.indexOf('<', start);
        if (start > 0 && end > start) {
          results.add(line.substring(start, end).trim());
        }
      }
      if (results.length >= 10) break;
    }

    return results;
  }
}

/// A tool's declared interface.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// Names of parameters the model must supply.
  ///
  /// This used to be derived from a per-parameter `optional` key that no
  /// definition ever set, so `!parameters[k]['optional']` was a null-check on
  /// `null` and building any schema threw. An explicit list cannot be forgotten
  /// into a crash: it is a required constructor argument.
  final List<String> required;

  /// Whether this tool actually works. Unimplemented tools are hidden from the
  /// model entirely.
  final bool implemented;

  final String? unimplementedReason;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
    required this.required,
    required this.implemented,
    this.unimplementedReason,
  });

  /// JSON Schema for this tool, built by encoding a real map.
  ///
  /// The previous version interpolated strings directly, so a description
  /// containing a quote produced invalid JSON that the model could not parse.
  /// `jsonEncode` escapes correctly by construction.
  String get schema => jsonEncode({
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': {
            for (final entry in parameters.entries)
              entry.key: {
                'type': (entry.value as Map)['type'],
                'description': (entry.value as Map)['description'],
              },
          },
          'required': required,
        },
      });
}
