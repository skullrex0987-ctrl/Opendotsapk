/// Activity screen.
///
/// Two tabs, because there are two genuinely different things worth looking at:
///
///  * **Tool activity** — what the agent did (from the database).
///  * **Diagnostics**   — the app's own `Log` ring.
///
/// The diagnostics tab exists because without it a runtime failure is
/// invisible. `Log` keeps a bounded in-memory ring precisely so bug reports can
/// read it, but nothing in the UI ever rendered it, and `debugPrint` is stripped
/// from release builds — so on a real phone the reason a model failed to load
/// was unreadable. "Vision failed to attach" with no cause is exactly that gap.
///
/// Tool activity is drawn as a timeline: tool calls are events, they happen in
/// order, and the order is the information. A flat card list threw that away.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/log.dart';
import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Activity'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Tool activity'),
              Tab(text: 'Diagnostics'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_ToolActivityTab(), _DiagnosticsTab()],
        ),
      ),
    );
  }
}

/// A day of activity: the header plus the entries under it.
class _DayGroup {
  _DayGroup(this.label, this.entries);

  /// "Today", "Yesterday", or a date.
  final String label;
  final List<Map<String, dynamic>> entries;
}

/// Historical list of tool calls, read from the database.
class _ToolActivityTab extends ConsumerWidget {
  const _ToolActivityTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activityLog = ref.watch(activityLogProvider);

    return Column(
      children: [
        _Toolbar(
          actions: [
            _ToolbarAction(
              icon: Icons.refresh,
              label: 'Refresh',
              onPressed: () => ref.read(activityLogProvider.notifier).refresh(),
            ),
          ],
        ),
        Expanded(
          child: activityLog.isEmpty
              ? const ScreenEmptyState(
                  icon: Icons.history,
                  title: 'No activity yet',
                  message:
                      'Every tool the agent runs is recorded here, newest '
                      'first.',
                )
              : _Timeline(entries: activityLog),
        ),
      ],
    );
  }
}

/// Groups [entries] by calendar day, preserving the incoming order.
///
/// Returns null when no entry carries a usable timestamp: the caller then
/// renders the flat timeline rather than pretending to have days. A day header
/// over rows that all belong to "no date" would be a lie in the other
/// direction.
List<_DayGroup>? _groupByDay(List<Map<String, dynamic>> entries) {
  final groups = <_DayGroup>[];
  int? currentKey;

  for (final entry in entries) {
    final ms = _timestampOf(entry);
    if (ms == null) return null;

    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    final key = DateTime(
      date.year,
      date.month,
      date.day,
    ).millisecondsSinceEpoch;

    if (key != currentKey) {
      currentKey = key;
      groups.add(_DayGroup(_dayLabel(date), <Map<String, dynamic>>[]));
    }
    groups.last.entries.add(entry);
  }

  return groups.isEmpty ? null : groups;
}

int? _timestampOf(Map<String, dynamic> entry) {
  final raw = entry['timestamp'];
  if (raw is int) return raw;
  // The column can come back as a string depending on the driver version;
  // a timeline that drops entries it cannot parse loses exactly the ones a
  // bug report needs.
  if (raw is String) return int.tryParse(raw);
  return null;
}

String _dayLabel(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final diff = today.difference(day).inDays;

  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${date.day}/${date.month}/${date.year}';
}

/// The vertical rail with a dot per event.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.entries});

  final List<Map<String, dynamic>> entries;

  @override
  Widget build(BuildContext context) {
    final groups = _groupByDay(entries);

    if (groups == null) {
      // No timestamps: the rail still communicates order, it just cannot be
      // labelled with days.
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: entries.length,
        itemBuilder: (context, index) => FadeSlideIn(
          delay: staggerDelay(index),
          child: _TimelineRow(entry: entries[index], isFirst: index == 0),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: groups.length,
      itemBuilder: (context, groupIndex) {
        final group = groups[groupIndex];
        final isFirstGroup = groupIndex == 0;

        final rows = <Widget>[];
        for (var i = 0; i < group.entries.length; i++) {
          rows.add(
            _TimelineRow(
              entry: group.entries[i],
              // The rail is continuous across the whole list, so only the very
              // first row suppresses the segment above its dot.
              isFirst: isFirstGroup && i == 0,
            ),
          );
        }

        return FadeSlideIn(
          delay: staggerDelay(groupIndex),
          child: Column(
            key: ValueKey<int>(groupIndex),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(
                  top: isFirstGroup ? 4 : 20,
                  bottom: 8,
                  left: 4,
                ),
                child: Text(
                  group.label,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
              ),
              ...rows,
            ],
          ),
        );
      },
    );
  }
}

/// One event on the rail.
///
/// The rail is drawn as a stack: a full-height line inset from the left edge
/// and a dot centred on it. Drawing it inside an [IntrinsicHeight] row would
/// make the line stop at the card's own height, which produces a broken
/// staircase wherever two entries have different amounts of text.
class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.entry, required this.isFirst});

  final Map<String, dynamic> entry;

  /// True for the very first row, where the rail must not extend above the
  /// dot — there is no earlier event to connect to.
  final bool isFirst;

  static const double _railX = 13;
  static const double _dotSize = 10;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = _statusColor(entry['status'] as String?);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Stack(
        children: [
          // The rail behind everything, running the full height of the row so
          // it meets the next row's rail without a gap.
          Positioned(
            left: _railX,
            top: isFirst ? 18 : 0,
            bottom: 0,
            width: 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: ActivityEntry(entry: entry, tint: tint),
          ),
          Positioned(
            left: _railX - _dotSize / 2,
            top: 13,
            child: Container(
              width: _dotSize,
              height: _dotSize,
              decoration: BoxDecoration(
                color: tint,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Map the stored status string onto the semantic palette.
  ///
  /// The old code treated everything that was not exactly 'success' as a
  /// failure, so a denied permission and a crashed tool looked identical in
  /// the log. They are different outcomes and the colour now says which.
  static Color _statusColor(String? status) {
    switch (status) {
      case 'success':
        return AppColors.success;
      case 'error':
        return AppColors.danger;
      case 'denied':
      case 'blocked':
        return AppColors.warning;
      default:
        return AppColors.accent;
    }
  }
}

/// Activity entry widget
class ActivityEntry extends StatelessWidget {
  final Map<String, dynamic> entry;

  /// Status tint, supplied by the timeline so the dot and the card agree.
  /// Falls back to the default text colour when used standalone.
  final Color? tint;

  const ActivityEntry({super.key, required this.entry, this.tint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = entry['status'] as String?;
    final colour =
        tint ??
        (status == 'success'
            ? AppColors.success
            : status == 'error'
            ? AppColors.danger
            : AppColors.accent);
    final isSuccess = status == 'success';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isSuccess ? Icons.check : Icons.error_outline,
                    size: 16,
                    color: colour,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    (entry['tool_name'] as String?) ?? 'Unknown tool',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _PermissionChip(level: entry['permission_level']),
              ],
            ),
            const SizedBox(height: 10),
            if (entry['params'] != null)
              _DetailLine(label: 'Params', value: '${entry['params']}'),
            if (entry['result'] != null)
              _DetailLine(label: 'Result', value: '${entry['result']}'),
            if (_formatTimestamp(_timestampOf(entry)).isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _formatTimestamp(_timestampOf(entry)),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(int? timestamp) {
    if (timestamp == null) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.day}/${date.month}/${date.year} '
        '${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}

/// A labelled parameter or result line.
///
/// Monospaced and dimmed: these are machine payloads, not prose, and setting
/// them in the body face at full contrast made the useful part — the tool name
/// and whether it worked — harder to find.
class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(text: '$label: ', style: theme.textTheme.labelSmall),
            TextSpan(
              text: value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The allow / ask / block word on an entry.
class _PermissionChip extends StatelessWidget {
  const _PermissionChip({required this.level});

  final Object? level;

  @override
  Widget build(BuildContext context) {
    final text = '${level ?? 'ask'}';
    final tint = switch (text) {
      'allow' => AppColors.success,
      'block' => AppColors.danger,
      _ => AppColors.warning,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tint),
      ),
    );
  }
}

/// A row of text actions at the top of a tab.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.actions});

  final List<_ToolbarAction> actions;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: actions);
  }
}

/// One toolbar button.
class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onPressed,
    );
  }
}

/// The `Log` ring, finally reachable by the user.
///
/// Copy-to-clipboard is the important affordance: the point of this tab is to
/// get the actual failure text out of the phone.
class _DiagnosticsTab extends StatefulWidget {
  const _DiagnosticsTab();

  @override
  State<_DiagnosticsTab> createState() => _DiagnosticsTabState();
}

class _DiagnosticsTabState extends State<_DiagnosticsTab> {
  @override
  Widget build(BuildContext context) {
    final entries = Log.recent(limit: 500);

    return Column(
      children: [
        _Toolbar(
          actions: [
            _ToolbarAction(
              icon: Icons.copy,
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: Log.dump()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Diagnostics copied')),
                  );
                }
              },
            ),
            _ToolbarAction(
              icon: Icons.refresh,
              label: 'Refresh',
              onPressed: () => setState(() {}),
            ),
            _ToolbarAction(
              icon: Icons.delete_sweep,
              label: 'Clear',
              onPressed: () => setState(Log.clear),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const ScreenEmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'Nothing logged yet',
                  message: 'Load a model, then come back.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final tint = _colorFor(entry.level);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 3),
                      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
                      decoration: BoxDecoration(
                        color: tint != null
                            ? tint.withValues(alpha: 0.06)
                            : null,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // A level gutter so `error` and `warn` can be found
                          // by scanning the left edge of a 500-line dump
                          // instead of reading each line.
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 1),
                            child: Text(
                              entry.level.name.substring(0, 1).toUpperCase(),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: tint ?? AppColors.accent,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              entry.formatted,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                height: 1.35,
                                color:
                                    tint ??
                                    Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Color? _colorFor(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return AppColors.danger;
      case LogLevel.warn:
        return AppColors.warning;
      case LogLevel.info:
        return AppColors.accent;
      case LogLevel.debug:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }
}
