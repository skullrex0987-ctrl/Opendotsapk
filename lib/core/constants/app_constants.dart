/// Core constants used throughout the application.
import 'package:flutter/material.dart';

class AppConstants {
  AppConstants._();

  // ---------------------------------------------------------------- app info
  static const String appName = 'LocalMind';
  static const String appVersion = '1.0.0';
  static const Color primaryColor = Color(0xFF6366F1);

  // ------------------------------------------------------------ model storage
  /// Sub-directory (under the app documents dir) holding downloaded GGUFs.
  static const String modelsDirName = 'models';

  /// Key in shared_preferences holding the selected chat model id.
  static const String prefActiveLlmId = 'active_llm_id';

  /// Key in shared_preferences holding the selected vision model id.
  static const String prefActiveVisionId = 'active_vision_id';
  static const String prefActiveEmbeddingId = 'active_embedding_id';

  // --------------------------------------------------------- inference settings
  static const int defaultContextSize = 2048;
  static const List<int> contextSizes = [1024, 2048, 4096];

  // ---------------------------------------------------------------- embeddings
  static const String embeddingModelName = 'all-MiniLM-L6-v2';
  static const int embeddingDimension = 384;

  // ------------------------------------------------------------------ database
  static const String databaseName = 'localmind.db';
  static const int vectorDimension = 384;

  // ---------------------------------------------------------------------- RAG
  static const int defaultMemoryCount = 5;
  static const double similarityThreshold = 0.7;

  // ------------------------------------------------------------- agent prompts
  static const String plannerPrompt = '''You are the Planner agent. Your job is to break down the user's request into a sequence of steps. You have access to the following tools:

- send_sms: Send an SMS message
- create_calendar_event: Create a calendar event
- add_contact: Add a new contact
- set_alarm: Set an alarm
- open_app: Open an app by package name
- web_search: Search the web using DuckDuckGo
- get_location: Get current location
- create_note: Create a note
- read_notes: Read notes

Output a JSON object with a single key "plan" which is an array of steps. Each step has "step" (description), "tool" (tool name or null), and "params" (object).
If no tools are needed, return a plan with a single step that says "Answer directly".
Do not include any other text outside the JSON.''';

  static const String executorPrompt = '''You are the Executor agent. You will receive a step from the plan and the conversation history.
If the step requires a tool, output a JSON object with "tool" and "params".
If the step requires a direct answer, output the answer as plain text.
Do not include any other text outside the JSON if calling a tool.''';

  static const String criticPrompt = '''You are the Critic agent. Review the Executor's output for correctness and completeness.
If the output is satisfactory, respond with "APPROVED".
If not, respond with "REVISE: <your suggestions>".
Be concise.''';

  // ---------------------------------------------------------------- tool names
  static const String toolSendSms = 'send_sms';
  static const String toolCalendarEvent = 'create_calendar_event';
  static const String toolAddContact = 'add_contact';
  static const String toolSetAlarm = 'set_alarm';
  static const String toolOpenApp = 'open_app';
  static const String toolWebSearch = 'web_search';
  static const String toolGetLocation = 'get_location';
  static const String toolCreateNote = 'create_note';
  static const String toolReadNotes = 'read_notes';

  // ----------------------------------------------------------- permission levels
  static const String permissionAllow = 'allow';
  static const String permissionAsk = 'ask';
  static const String permissionBlock = 'block';

  static const Map<String, String> defaultPermissions = {
    toolSendSms: permissionAsk,
    toolCalendarEvent: permissionAsk,
    toolAddContact: permissionAsk,
    toolSetAlarm: permissionAsk,
    toolOpenApp: permissionAsk,
    toolWebSearch: permissionAllow,
    toolGetLocation: permissionAsk,
    toolCreateNote: permissionAllow,
    toolReadNotes: permissionAllow,
  };

  // -------------------------------------------------------------- personalities
  static const Map<String, String> personalities = {
    'professional': 'You are a professional AI assistant. Be concise and accurate.',
    'friendly': 'You are a friendly AI assistant. Be warm and conversational.',
    'concise': 'You are a concise AI assistant. Be brief and to the point.',
  };
}
