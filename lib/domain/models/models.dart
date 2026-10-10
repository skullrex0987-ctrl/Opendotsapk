/// Message model for chat conversations
import 'dart:convert';

class ChatMessage {
  final String id;
  final String role; // 'user' or 'assistant'
  final String content;
  final int timestamp;
  final String? sessionId;
  
  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.sessionId,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp,
      'session_id': sessionId,
    };
  }
  
  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      id: map['id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      timestamp: map['timestamp'] as int,
      sessionId: map['session_id'] as String?,
    );
  }
  
  ChatMessage copyWith({
    String? id,
    String? role,
    String? content,
    int? timestamp,
    String? sessionId,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      sessionId: sessionId ?? this.sessionId,
    );
  }
}

/// Tool call model
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> params;
  final String? result;
  
  ToolCall({
    required this.id,
    required this.name,
    required this.params,
    this.result,
  });
  
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'params': params.toString(),
      'result': result,
    };
  }
  
  factory ToolCall.fromMap(Map<String, dynamic> map) {
    // `params` may arrive as a JSON string (from the agent pipeline) or as a
    // decoded map (from a database row). Handle both instead of hard-casting.
    final rawParams = map['params'];
    Map<String, dynamic> params;
    if (rawParams is Map) {
      params = Map<String, dynamic>.from(rawParams);
    } else if (rawParams is String && rawParams.isNotEmpty) {
      try {
        params = Map<String, dynamic>.from(
          jsonDecode(rawParams) as Map,
        );
      } catch (_) {
        params = <String, dynamic>{};
      }
    } else {
      params = <String, dynamic>{};
    }

    return ToolCall(
      id: map['id'] as String,
      name: map['name'] as String,
      params: params,
      result: map['result'] as String?,
    );
  }
}

/// Plan model from Planner agent
class AgentPlan {
  final List<PlanStep> steps;
  
  AgentPlan({required this.steps});
  
  factory AgentPlan.fromJson(Map<String, dynamic> json) {
    final steps = json['plan'] as List<dynamic>;
    return AgentPlan(
      steps: steps.map((s) => PlanStep.fromMap(s as Map<String, dynamic>)).toList(),
    );
  }
  
  Map<String, dynamic> toJson() {
    return {'plan': steps.map((s) => s.toMap()).toList()};
  }
}

/// Individual step in a plan
class PlanStep {
  final String description;
  final String? toolName;
  final Map<String, dynamic> params;
  
  PlanStep({
    required this.description,
    this.toolName,
    this.params = const {},
  });
  
  factory PlanStep.fromMap(Map<String, dynamic> map) {
    return PlanStep(
      description: map['step'] as String,
      toolName: map['tool'] as String?,
      params: Map<String, dynamic>.from(map['params'] ?? {}),
    );
  }
  
  Map<String, dynamic> toMap() {
    return {
      'step': description,
      'tool': toolName,
      'params': params,
    };
  }
}

/// Tool execution result
class ToolResult {
  final String toolName;
  final String result;
  final bool success;
  final String? error;
  
  ToolResult({
    required this.toolName,
    required this.result,
    this.success = true,
    this.error,
  });
  
  Map<String, dynamic> toJson() {
    return {
      'tool': toolName,
      'result': result,
      'success': success,
      'error': error,
    };
  }
}

/// Memory entry for RAG
class MemoryEntry {
  final String id;
  final String content;
  final int timestamp;
  final List<double> embedding;
  
  MemoryEntry({
    required this.id,
    required this.content,
    required this.timestamp,
    required this.embedding,
  });
}
