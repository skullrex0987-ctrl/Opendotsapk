/// Tiny levelled logger.
///
/// `debugPrint` is stripped in release builds, which is exactly when a bug
/// report needs logs. This keeps a bounded in-memory ring that the Activity
/// screen and bug reports can read, and it is also where crash-relevant
/// messages go — no third-party service, nothing leaves the device.
library;

import 'dart:collection';

import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;

  const LogEntry(this.time, this.level, this.message);

  String get formatted {
    final t = time.toIso8601String().substring(11, 19);
    final tag = level.name.toUpperCase().padRight(5);
    return '$t $tag $message';
  }
}

class Log {
  Log._();

  /// Bounded so a long-running session cannot grow without limit.
  static const int _maxEntries = 500;

  static final Queue<LogEntry> _entries = Queue<LogEntry>();

  /// Mirror to logcat in debug builds only.
  static bool mirrorToConsole = kDebugMode;

  static void _add(LogLevel level, String message) {
    _entries.addLast(LogEntry(DateTime.now(), level, message));
    while (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
    if (mirrorToConsole) {
      debugPrint('[${level.name}] $message');
    }
  }

  static void d(String message) => _add(LogLevel.debug, message);
  static void i(String message) => _add(LogLevel.info, message);
  static void w(String message) => _add(LogLevel.warn, message);
  static void e(String message) => _add(LogLevel.error, message);

  /// Most recent first.
  static List<LogEntry> recent({int limit = 200, LogLevel? minLevel}) {
    final all = _entries.toList().reversed;
    final out = <LogEntry>[];
    for (final e in all) {
      if (minLevel != null && e.level.index < minLevel.index) continue;
      out.add(e);
      if (out.length >= limit) break;
    }
    return out;
  }

  static void clear() => _entries.clear();

  /// Plain-text dump for the "copy diagnostics" button.
  static String dump() =>
      recent(limit: _maxEntries).map((e) => e.formatted).join('\n');
}
