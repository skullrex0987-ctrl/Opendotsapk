/// The outcome of a tool call.
///
/// Tools used to return a bare `String` containing JSON, and several of them
/// returned `{"status":"success"}` without doing anything at all. A model that
/// is told a tool succeeded will confidently tell the user their SMS was sent.
/// The type below exists so that "it worked" is a claim a tool has to actually
/// make, in a form the caller can branch on, and so that the failures a device
/// can produce are distinguishable from one another:
///
/// * [failed]            — we tried, it broke (a real error, with a reason).
/// * [unsupported]       — we cannot do this here at all. Never a success, so
///                         the model is told the truth and the tool is hidden.
/// * [requiresPermission]— Android permission missing; the user must grant it.
/// * [awaitingConfirmation] — the user must approve before anything happens.
/// * [requiresUserAction]— we opened a system UI (SMS composer, alarm app) and
///                         the user must finish the action themselves. This is
///                         NOT success: nothing has happened yet.
///
/// Only [success] may be reported to the model as a completed action.
library;

import 'dart:convert';

enum ToolStatus {
  success,
  failed,
  unsupported,
  requiresPermission,
  awaitingConfirmation,
  requiresUserAction,
}

extension ToolStatusWire on ToolStatus {
  /// The string the model sees. Kept stable and explicit.
  String get wire => switch (this) {
        ToolStatus.success => 'success',
        ToolStatus.failed => 'failed',
        ToolStatus.unsupported => 'unsupported',
        ToolStatus.requiresPermission => 'requires_permission',
        ToolStatus.awaitingConfirmation => 'awaiting_confirmation',
        ToolStatus.requiresUserAction => 'requires_user_action',
      };
}

class ToolResult {
  final ToolStatus status;

  /// Human-readable explanation. Required for everything except success, so a
  /// failure can never be reported without saying why.
  final String message;

  /// Structured payload, present only on success.
  final Map<String, dynamic>? data;

  const ToolResult._(this.status, this.message, {this.data});

  factory ToolResult.success(String message, {Map<String, dynamic>? data}) =>
      ToolResult._(ToolStatus.success, message, data: data);

  factory ToolResult.failed(String message) =>
      ToolResult._(ToolStatus.failed, message);

  factory ToolResult.unsupported(String message) =>
      ToolResult._(ToolStatus.unsupported, message);

  factory ToolResult.requiresPermission(String message) =>
      ToolResult._(ToolStatus.requiresPermission, message);

  factory ToolResult.awaitingConfirmation(String message) =>
      ToolResult._(ToolStatus.awaitingConfirmation, message);

  factory ToolResult.requiresUserAction(String message,
          {Map<String, dynamic>? data}) =>
      ToolResult._(ToolStatus.requiresUserAction, message, data: data);

  bool get isSuccess => status == ToolStatus.success;

  /// Whether the model should be told this was achieved. Only [success].
  bool get isCompletedAction => status == ToolStatus.success;

  Map<String, dynamic> toMap() => {
        'status': status.wire,
        'message': message,
        if (data != null) ...data!,
      };

  String toJson() => jsonEncode(toMap());

  @override
  String toString() => 'ToolResult(${status.wire}: $message)';
}
