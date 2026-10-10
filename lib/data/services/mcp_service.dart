/// Model Context Protocol client.
///
/// MCP is the reason this file exists: the app hand-writes nine tools, and MCP
/// turns that ceiling into "however many servers the user wants to add".
/// Anything speaking MCP becomes available to the agent with no new Dart code.
///
/// Transport: HTTP (Streamable HTTP / SSE) only — stdio servers need a child
/// process, which is not available to a normal Android app and would be a poor
/// security default anyway.
///
/// Implemented directly against the JSON-RPC surface rather than pulling in an
/// SDK. The protocol subset the agent needs is small (`initialize`,
/// `tools/list`, `tools/call`), and the app already ships three native
/// runtimes; every megabyte matters.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/utils/log.dart';

class McpTool {
  final String name;
  final String description;

  /// JSON Schema for the tool's arguments.
  final Map<String, dynamic> inputSchema;

  /// Which server exposed this tool.
  final String serverId;

  const McpTool({
    required this.name,
    required this.description,
    required this.serverId,
    this.inputSchema = const {'type': 'object', 'properties': {}},
  });

  /// Namespaced name so two servers can both expose `search`.
  String get qualifiedName => '$serverId:$name';
}

class McpServerConfig {
  final String id;
  final String name;

  /// Streamable-HTTP endpoint, e.g. `https://host/mcp`.
  final String url;

  /// Optional bearer token. Stored in the keystore, not here.
  final bool requiresAuth;

  final bool enabled;

  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.requiresAuth = false,
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'requiresAuth': requiresAuth,
        'enabled': enabled,
      };

  static McpServerConfig fromJson(Map<String, dynamic> j) => McpServerConfig(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        url: j['url'] as String,
        requiresAuth: j['requiresAuth'] as bool? ?? false,
        enabled: j['enabled'] as bool? ?? true,
      );
}

class McpException implements Exception {
  final String message;
  const McpException(this.message);

  @override
  String toString() => message;
}

class McpService {
  McpService._();

  static McpService? _instance;
  static McpService get instance => _instance ??= McpService._();

  final http.Client _client = http.Client();

  final List<McpServerConfig> _servers = [];

  /// Tools discovered per server id.
  final Map<String, List<McpTool>> _tools = {};

  /// Session ids handed out by servers during `initialize`.
  final Map<String, String> _sessions = {};

  int _nextId = 1;

  List<McpServerConfig> get servers => List.unmodifiable(_servers);

  List<McpTool> get allTools =>
      _tools.values.expand((t) => t).toList(growable: false);

  bool get hasTools => _tools.values.any((t) => t.isNotEmpty);

  /// Replace the configured server list. Does not connect.
  void configure(List<McpServerConfig> servers) {
    _servers
      ..clear()
      ..addAll(servers);
    _tools.clear();
    _sessions.clear();
    Log.i('mcp: ${servers.length} server(s) configured');
  }

  void addServer(McpServerConfig server) {
    _servers.removeWhere((s) => s.id == server.id);
    _servers.add(server);
  }

  void removeServer(String id) {
    _servers.removeWhere((s) => s.id == id);
    _tools.remove(id);
    _sessions.remove(id);
  }

  /// Connect to every enabled server and discover its tools.
  ///
  /// Failures are per-server and never fatal: a broken MCP server must not stop
  /// the app from starting or the local model from working.
  Future<Map<String, String>> connectAll({String? authToken}) async {
    final errors = <String, String>{};
    for (final s in _servers) {
      if (!s.enabled) continue;
      try {
        await connect(s, authToken: authToken);
      } catch (e) {
        errors[s.id] = '$e';
        Log.w('mcp: connect failed for ${s.id}: $e');
      }
    }
    return errors;
  }

  /// Run `initialize` then `tools/list` against one server.
  Future<List<McpTool>> connect(
    McpServerConfig server, {
    String? authToken,
  }) async {
    final init = await _rpc(
      server,
      'initialize',
      {
        'protocolVersion': '2025-06-18',
        'capabilities': {
          'tools': <String, dynamic>{},
          'roots': {'listChanged': false},
        },
        'clientInfo': {'name': 'LocalMind', 'version': '1.1.0'},
      },
      authToken: authToken,
    );

    final sessionId = init['_sessionId'] as String?;
    if (sessionId != null) _sessions[server.id] = sessionId;

    // Best-effort: some servers require the notification to finish handshaking.
    try {
      await _notify(server, 'notifications/initialized', const {},
          authToken: authToken, sessionId: sessionId);
    } catch (_) {
      // Optional.
    }

    final listed = await _rpc(server, 'tools/list', const {},
        authToken: authToken, sessionId: sessionId);

    final raw = listed['tools'];
    final tools = <McpTool>[];
    if (raw is List) {
      for (final t in raw) {
        if (t is! Map) continue;
        tools.add(McpTool(
          name: '${t['name']}',
          description: '${t['description'] ?? ''}',
          serverId: server.id,
          inputSchema: (t['inputSchema'] is Map)
              ? Map<String, dynamic>.from(t['inputSchema'] as Map)
              : const {'type': 'object', 'properties': {}},
        ));
      }
    }

    _tools[server.id] = tools;
    Log.i('mcp: ${server.id} exposed ${tools.length} tool(s)');
    return tools;
  }

  /// Invoke a tool by its `serverId:toolName` qualified name.
  Future<String> callTool(
    String qualifiedName,
    Map<String, dynamic> arguments, {
    String? authToken,
  }) async {
    final idx = qualifiedName.indexOf(':');
    if (idx <= 0) {
      throw McpException('Malformed MCP tool name: $qualifiedName');
    }
    final serverId = qualifiedName.substring(0, idx);
    final toolName = qualifiedName.substring(idx + 1);

    final server = _servers.cast<McpServerConfig?>().firstWhere(
          (s) => s?.id == serverId,
          orElse: () => null,
        );
    if (server == null) {
      throw McpException('Unknown MCP server: $serverId');
    }

    final result = await _rpc(
      server,
      'tools/call',
      {'name': toolName, 'arguments': arguments},
      authToken: authToken,
      sessionId: _sessions[serverId],
    );

    return _flattenContent(result);
  }

  /// MCP returns a list of content blocks; join the text ones.
  static String _flattenContent(Map<String, dynamic> result) {
    final buf = StringBuffer();

    final content = result['content'];
    if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        final type = block['type'];
        if (type == 'text') {
          buf.writeln(block['text']);
        } else if (type == 'resource') {
          final res = block['resource'];
          if (res is Map && res['text'] != null) buf.writeln(res['text']);
        } else {
          buf.writeln('[${type ?? 'unknown'} content]');
        }
      }
    }

    if (result['isError'] == true) {
      return 'Tool error: ${buf.toString().trim()}';
    }

    final text = buf.toString().trim();
    return text.isEmpty ? '(no output)' : text;
  }

  // ------------------------------------------------------------- JSON-RPC

  Future<Map<String, dynamic>> _rpc(
    McpServerConfig server,
    String method,
    Map<String, dynamic> params, {
    String? authToken,
    String? sessionId,
  }) async {
    final id = _nextId++;
    final body = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };

    final response = await _post(server, body,
        authToken: authToken, sessionId: sessionId);

    if (response.containsKey('error')) {
      final err = response['error'];
      throw McpException(
        '${server.name}: ${err is Map ? err['message'] : err}',
      );
    }

    final result = response['result'];
    final out = result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{'value': result};

    if (response['_sessionId'] != null) {
      out['_sessionId'] = response['_sessionId'];
    }
    return out;
  }

  Future<void> _notify(
    McpServerConfig server,
    String method,
    Map<String, dynamic> params, {
    String? authToken,
    String? sessionId,
  }) async {
    final body = {'jsonrpc': '2.0', 'method': method, 'params': params};
    await _post(server, body,
        authToken: authToken, sessionId: sessionId, expectId: false);
  }

  Future<Map<String, dynamic>> _post(
    McpServerConfig server,
    Map<String, dynamic> body, {
    String? authToken,
    String? sessionId,
    bool expectId = true,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      // Both are advertised because servers differ on which they honour.
      'Accept': 'application/json, text/event-stream',
    };
    if (authToken != null && authToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $authToken';
    }
    if (sessionId != null) {
      headers['Mcp-Session-Id'] = sessionId;
    }
    if (expectId) headers['MCP-Protocol-Version'] = '2025-06-18';

    late final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse(server.url),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw McpException('${server.name}: timed out after 30s');
    } catch (e) {
      throw McpException('${server.name}: network error — $e');
    }

    if (res.statusCode >= 400) {
      final hint = res.statusCode == 401 || res.statusCode == 403
          ? ' (the server may need a token)'
          : '';
      throw McpException(
        '${server.name}: HTTP ${res.statusCode}$hint',
      );
    }

    if (!expectId) return const {};

    final text = res.body.trim();
    if (text.isEmpty) return const {};

    // Servers may reply with SSE framing even to a single request.
    final payload = text.startsWith('event:') || text.startsWith('data:')
        ? _lastDataLine(text)
        : text;

    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw McpException('${server.name}: unexpected reply shape');
      }
      final out = Map<String, dynamic>.from(decoded);
      final sid = res.headers['mcp-session-id'];
      if (sid != null) out['_sessionId'] = sid;
      return out;
    } catch (e) {
      if (e is McpException) rethrow;
      throw McpException('${server.name}: could not parse reply — $e');
    }
  }

  static String _lastDataLine(String sse) {
    String? last;
    for (final line in sse.split('\n')) {
      if (line.startsWith('data:')) last = line.substring(5).trim();
    }
    return last ?? sse;
  }

  void dispose() => _client.close();
}
