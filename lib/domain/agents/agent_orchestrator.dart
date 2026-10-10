/// Agent orchestration system
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../../data/services/llm_service.dart';
import '../../data/tools/tool_registry.dart';
import '../../data/database/database_helper.dart';

class AgentOrchestrator {
  static final AgentOrchestrator _instance = AgentOrchestrator._internal();
  factory AgentOrchestrator() => _instance;
  AgentOrchestrator._internal();
  
  final LlmService _llm = LlmService.getInstance();
  final ToolRegistry _tools = ToolRegistry();
  final DatabaseHelper _db = DatabaseHelper();
  final Uuid _uuid = const Uuid();
  
  /// Process user message through multi-agent pipeline
  Future<String> processMessage({
    required String userMessage,
    required List<ChatMessage> conversationHistory,
    List<MemoryEntry>? relevantMemories,
  }) async {
    try {
      // Build context with memories
      final memoryContext = relevantMemories != null && relevantMemories.isNotEmpty
          ? '\n\nRelevant past memories:\n${relevantMemories.map((m) => m.content).join('\n')}'
          : '';
      
      // Step 1: Planner
      final plan = await _plan(userMessage, conversationHistory, memoryContext);
      
      // Step 2: Executor (execute each step)
      final results = await _executePlan(plan, conversationHistory);
      
      // Step 3: Critic
      final finalResponse = await _critique(results, conversationHistory);
      
      return finalResponse;
    } catch (e) {
      print('Agent pipeline error: $e');
      return 'I encountered an error while processing your request. Please try again.';
    }
  }
  
  /// Planner: Break down request into steps
  Future<AgentPlan> _plan(
    String message,
    List<ChatMessage> history,
    String memoryContext,
  ) async {
    final toolSchemas = _tools.tools.values.map((t) => t.schema).join('\n\n');
    
    final prompt = '''$memoryContext

User: $message

Assistant: I need to plan how to handle this request. Here are the available tools:

$toolSchemas

Remember, output ONLY valid JSON with a "plan" key containing an array of steps. Each step must have "step" (description), "tool" (tool name or null), and "params" (object).''';
    
    final response = await _llm.generate(prompt: prompt, maxTokens: 1024);
    
    try {
      final json = jsonDecode(response) as Map<String, dynamic>;
      return AgentPlan.fromJson(json);
    } catch (e) {
      // Fallback: single direct answer step
      return AgentPlan(steps: [
        PlanStep(description: 'Answer directly', toolName: null),
      ]);
    }
  }
  
  /// Executor: Execute each step
  Future<Map<String, dynamic>> _executePlan(
    AgentPlan plan,
    List<ChatMessage> history,
  ) async {
    final results = <String, dynamic>{};
    
    for (final step in plan.steps) {
      if (step.toolName == null) {
        // Direct answer - no tool needed
        results['direct_answer'] = step.description;
      } else {
        // Execute tool
        final toolResult = await _executeStep(step, history);
        results[step.toolName!] = toolResult;
      }
    }
    
    return results;
  }
  
  /// Execute a single step
  Future<String> _executeStep(PlanStep step, List<ChatMessage> history) async {
    final toolName = step.toolName!;
    final params = step.params;
    final permission = _tools.getPermission(toolName);
    
    // Check permission
    if (permission == 'block') {
      return jsonEncode({'error': 'Tool "$toolName" is blocked by user settings'});
    }
    
    // If ask, we would show dialog (handled in UI layer)
    // For now, proceed with execution
    
    try {
      final result = await _tools.executeTool(
        toolName: toolName,
        params: params,
        permission: permission,
      );
      
      // Log activity
      await _logActivity(
        toolName: toolName,
        params: params.toString(),
        result: result,
        status: 'success',
        permissionLevel: permission,
      );
      
      return result;
    } catch (e) {
      await _logActivity(
        toolName: toolName,
        params: params.toString(),
        result: e.toString(),
        status: 'error',
        permissionLevel: permission,
      );
      return jsonEncode({'error': e.toString()});
    }
  }
  
  /// Critic: Review and finalize response
  Future<String> _critique(
    Map<String, dynamic> results,
    List<ChatMessage> history,
  ) async {
    // Build summary of execution
    final executionSummary = results.entries.map((e) {
      return 'Tool: ${e.key}\nResult: ${e.value}';
    }).join('\n\n');
    
    final prompt = '''Review the following execution results and provide a final response to the user.

Execution results:
$executionSummary

If the results are satisfactory, respond with "APPROVED" and then provide a helpful summary.
If not, respond with "REVISE: <suggestions>".''';
    
    final response = await _llm.generate(prompt: prompt, maxTokens: 512);
    
    if (response.contains('REVISE:')) {
      // Request revision - in production, loop back to planner
      final revised = await _planForRevision(response, history);
      return revised;
    }
    
    return response;
  }
  
  Future<String> _planForRevision(String critique, List<ChatMessage> history) async {
    final prompt = '''The critic suggests: $critique

Please revise the approach and provide a better plan or answer.''';
    
    return await _llm.generate(prompt: prompt, maxTokens: 512);
  }
  
  /// Log tool execution activity
  Future<void> _logActivity({
    required String toolName,
    required String params,
    required String result,
    required String status,
    required String permissionLevel,
  }) async {
    await _db.insertActivityLog(
      id: _uuid.v4(),
      toolName: toolName,
      params: params,
      result: result,
      status: status,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      permissionLevel: permissionLevel,
    );
  }
  
  /// Get related memories for RAG
  Future<List<MemoryEntry>> getRelatedMemories(String query) async {
    // Generate embedding for query
    // Search vector DB
    // Return top results
    return [];
  }
}
