/// Tool definitions and execution
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';

class ToolRegistry {
  static final ToolRegistry _instance = ToolRegistry._internal();
  factory ToolRegistry() => _instance;
  ToolRegistry._internal();
  
  final Map<String, ToolDefinition> _tools = {};
  final Map<String, String> _permissions = {};
  
  /// Register all available tools
  void registerTools() {
    _tools['send_sms'] = ToolDefinition(
      name: 'send_sms',
      description: 'Send an SMS message to a recipient',
      parameters: {
        'recipient': {'type': 'string', 'description': 'Phone number'},
        'message': {'type': 'string', 'description': 'Message content'},
      },
    );
    
    _tools['create_calendar_event'] = ToolDefinition(
      name: 'create_calendar_event',
      description: 'Create a calendar event',
      parameters: {
        'title': {'type': 'string', 'description': 'Event title'},
        'start_time': {'type': 'string', 'description': 'Start time (ISO8601)'},
        'end_time': {'type': 'string', 'description': 'End time (ISO8601)'},
        'location': {'type': 'string', 'description': 'Event location (optional)'},
      },
    );
    
    _tools['add_contact'] = ToolDefinition(
      name: 'add_contact',
      description: 'Add a new contact',
      parameters: {
        'name': {'type': 'string', 'description': 'Contact name'},
        'phone': {'type': 'string', 'description': 'Phone number'},
        'email': {'type': 'string', 'description': 'Email (optional)'},
      },
    );
    
    _tools['set_alarm'] = ToolDefinition(
      name: 'set_alarm',
      description: 'Set an alarm',
      parameters: {
        'time': {'type': 'string', 'description': 'Alarm time (ISO8601)'},
        'label': {'type': 'string', 'description': 'Alarm label (optional)'},
      },
    );
    
    _tools['open_app'] = ToolDefinition(
      name: 'open_app',
      description: 'Open an app by package name',
      parameters: {
        'package_name': {'type': 'string', 'description': 'App package name'},
      },
    );
    
    _tools['web_search'] = ToolDefinition(
      name: 'web_search',
      description: 'Search the web using DuckDuckGo',
      parameters: {
        'query': {'type': 'string', 'description': 'Search query'},
      },
    );
    
    _tools['get_location'] = ToolDefinition(
      name: 'get_location',
      description: 'Get current location',
      parameters: {},
    );
    
    _tools['create_note'] = ToolDefinition(
      name: 'create_note',
      description: 'Create a note',
      parameters: {
        'title': {'type': 'string', 'description': 'Note title'},
        'content': {'type': 'string', 'description': 'Note content'},
      },
    );
    
    _tools['read_notes'] = ToolDefinition(
      name: 'read_notes',
      description: 'Read notes matching query',
      parameters: {
        'query': {'type': 'string', 'description': 'Search query (optional)'},
      },
    );
    
    // Set default permissions
    for (final tool in _tools.keys) {
      _permissions[tool] = 'ask';
    }
  }
  
  /// Get all tool definitions
  Map<String, ToolDefinition> get tools => Map.unmodifiable(_tools);
  
  /// Set permission for a tool
  void setPermission(String toolName, String permission) {
    _permissions[toolName] = permission;
  }
  
  /// Get permission for a tool
  String getPermission(String toolName) => _permissions[toolName] ?? 'ask';
  
  /// Execute a tool
  Future<String> executeTool({
    required String toolName,
    required Map<String, dynamic> params,
    required String permission,
  }) async {
    if (!_tools.containsKey(toolName)) {
      return jsonEncode({'error': 'Tool not found: $toolName'});
    }
    
    switch (toolName) {
      case 'send_sms':
        return await _executeSendSms(params);
      case 'create_calendar_event':
        return await _executeCreateCalendarEvent(params);
      case 'add_contact':
        return await _executeAddContact(params);
      case 'set_alarm':
        return await _executeSetAlarm(params);
      case 'open_app':
        return await _executeOpenApp(params);
      case 'web_search':
        return await _executeWebSearch(params);
      case 'get_location':
        return await _executeGetLocation(params);
      case 'create_note':
        return await _executeCreateNote(params);
      case 'read_notes':
        return await _executeReadNotes(params);
      default:
        return jsonEncode({'error': 'Unknown tool: $toolName'});
    }
  }
  
  Future<String> _executeSendSms(Map<String, dynamic> params) async {
    // Check permission
    final hasPermission = await Permission.sms.request().isGranted;
    if (!hasPermission) {
      return jsonEncode({'error': 'SMS permission denied'});
    }
    
    // In production, use sms or flutter_sms package
    // This is a placeholder implementation
    return jsonEncode({
      'status': 'success',
      'message': 'SMS sent to ${params['recipient']}',
    });
  }
  
  Future<String> _executeCreateCalendarEvent(Map<String, dynamic> params) async {
    // Check permission
    final hasPermission = await Permission.calendar.request().isGranted;
    if (!hasPermission) {
      return jsonEncode({'error': 'Calendar permission denied'});
    }
    
    // In production, use flutter_native_calendar or similar
    return jsonEncode({
      'status': 'success',
      'message': 'Event "${params['title']}" created',
    });
  }
  
  Future<String> _executeAddContact(Map<String, dynamic> params) async {
    // Check permission
    final hasPermission = await Permission.contacts.request().isGranted;
    if (!hasPermission) {
      return jsonEncode({'error': 'Contacts permission denied'});
    }
    
    // In production, use contacts_service or similar
    return jsonEncode({
      'status': 'success',
      'message': 'Contact "${params['name']}" added',
    });
  }
  
  Future<String> _executeSetAlarm(Map<String, dynamic> params) async {
    // Check permission
    final hasPermission = await Permission.scheduleExactAlarm.request().isGranted;
    if (!hasPermission) {
      return jsonEncode({'error': 'Alarm permission denied'});
    }
    
    // In production, use android_alarm_manager_plus or similar
    return jsonEncode({
      'status': 'success',
      'message': 'Alarm set for ${params['time']}',
    });
  }
  
  Future<String> _executeOpenApp(Map<String, dynamic> params) async {
    // In production, use app_open or launch_package
    return jsonEncode({
      'status': 'success',
      'message': 'Opened app: ${params['package_name']}',
    });
  }
  
  Future<String> _executeWebSearch(Map<String, dynamic> params) async {
    final query = params['query'] as String;
    try {
      final response = await http.get(
        Uri.parse('https://lite.duckduckgo.com/lite/?q=${Uri.encodeComponent(query)}'),
      );
      
      // Parse HTML and extract results
      final String body = response.body;
      final List<String> results = _parseDuckDuckGoResults(body);
      
      return jsonEncode({
        'status': 'success',
        'query': query,
        'results': results.take(3).toList(),
      });
    } catch (e) {
      return jsonEncode({'error': 'Search failed: $e'});
    }
  }
  
  Future<String> _executeGetLocation(Map<String, dynamic> params) async {
    // Check permission
    final hasPermission = await Permission.location.request().isGranted;
    if (!hasPermission) {
      return jsonEncode({'error': 'Location permission denied'});
    }
    
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      
      return jsonEncode({
        'status': 'success',
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': position.timestamp.toIso8601String(),
      });
    } catch (e) {
      return jsonEncode({'error': 'Failed to get location: $e'});
    }
  }
  
  Future<String> _executeCreateNote(Map<String, dynamic> params) async {
    // In production, save to SQLite database
    return jsonEncode({
      'status': 'success',
      'message': 'Note "${params['title']}" created',
    });
  }
  
  Future<String> _executeReadNotes(Map<String, dynamic> params) async {
    // In production, query SQLite database
    final query = params['query'] as String?;
    return jsonEncode({
      'status': 'success',
      'notes': [],
      'query': query,
    });
  }
  
  List<String> _parseDuckDuckGoResults(String html) {
    // Simple HTML parsing - in production, use html parser package
    final results = <String>[];
    final lines = html.split('\n');
    
    for (final line in lines) {
      if (line.contains('class="result__a"') || 
          line.contains('result__title')) {
        // Extract result text
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

/// Tool definition
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  
  ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });
  
  String get schema {
    final paramsSchema = parameters.entries.map((e) {
      return '"${e.key}": {"type": "${e.value['type']}", "description": "${e.value['description']}"}';
    }).join(',\n        ');
    
    return '''{
    "name": "$name",
    "description": "$description",
    "parameters": {
      "type": "object",
      "properties": {
        $paramsSchema
      },
      "required": [${parameters.keys.where((k) => !parameters[k]['optional']).toList().map((k) => '"$k"').join(', ')}]
    }
  }''';
  }
}
