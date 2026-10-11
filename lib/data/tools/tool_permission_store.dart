/// Single source of truth for what each tool is allowed to do.
///
/// Before this existed there were two of these: a private map inside
/// `ToolRegistry` and a separate `PermissionsNotifier` in the UI layer. They
/// never spoke, so changing a permission in Settings did not change what the
/// agent did, and nothing survived a restart because the notifier's loader
/// never read anything back.
library;

import 'package:shared_preferences/shared_preferences.dart';

enum ToolPermission {
  allow,
  ask,
  block;

  String get wire => name;

  static ToolPermission parse(String? value) {
    return switch (value) {
      'allow' => ToolPermission.allow,
      'block' => ToolPermission.block,
      _ => ToolPermission.ask,
    };
  }
}

class ToolPermissionStore {
  static const _prefix = 'tool_permission.';

  final Map<String, ToolPermission> _cache = {};

  /// Every tool starts at [ToolPermission.ask].
  ///
  /// Not `allow`: a default of allow means a fresh install silently executes
  /// whatever the model decides to call. `ask` costs one tap and is the only
  /// honest default when the action leaves the device (SMS, contacts) or
  /// reveals where the user is.
  static ToolPermission defaultFor(String toolName) => ToolPermission.ask;

  /// Reads persisted permissions. Unknown tools keep the default.
  Future<void> load(Iterable<String> toolNames) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final name in toolNames) {
        final raw = prefs.getString('$_prefix$name');
        _cache[name] = raw == null ? defaultFor(name) : ToolPermission.parse(raw);
      }
    } catch (_) {
      // A read failure must not leave a tool unrestricted. Falling back to the
      // defaults (all `ask`) is the safe direction: worst case the user is
      // prompted more often than necessary.
      for (final name in toolNames) {
        _cache.putIfAbsent(name, () => defaultFor(name));
      }
    }
  }

  ToolPermission get(String toolName) =>
      _cache[toolName] ?? defaultFor(toolName);

  Map<String, ToolPermission> get all => Map.unmodifiable(_cache);

  Future<void> set(String toolName, ToolPermission permission) async {
    _cache[toolName] = permission;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_prefix$toolName', permission.wire);
    } catch (_) {
      // Keep the in-memory value: the session should honour the change even if
      // persistence failed, and the caller is told via the return of the UI.
    }
  }
}
