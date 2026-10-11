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
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/log.dart';
import '../providers/providers.dart';

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
          children: [
            _ToolActivityTab(),
            _DiagnosticsTab(),
          ],
        ),
      ),
    );
  }
}

/// Historical list of tool calls, read from the database.
class _ToolActivityTab extends ConsumerWidget {
  const _ToolActivityTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activityLog = ref.watch(activityLogProvider);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
              onPressed: () => ref.read(activityLogProvider.notifier).refresh(),
            ),
          ],
        ),
        Expanded(
          child: activityLog.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.history, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        'No activity yet',
                        style: TextStyle(fontSize: 18, color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: activityLog.length,
                  itemBuilder: (context, index) {
                    return ActivityEntry(entry: activityLog[index]);
                  },
                ),
        ),
      ],
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
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: Log.dump()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Diagnostics copied')),
                  );
                }
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
              onPressed: () => setState(() {}),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_sweep, size: 18),
              label: const Text('Clear'),
              onPressed: () => setState(Log.clear),
            ),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: entries.isEmpty
              ? const Center(
                  child: Text(
                    'Nothing logged yet.\nLoad a model, then come back.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        entry.formatted,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: _colorFor(entry.level),
                        ),
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
        return Colors.redAccent;
      case LogLevel.warn:
        return Colors.orangeAccent;
      case LogLevel.info:
        return null;
      case LogLevel.debug:
        return Colors.grey;
    }
  }
}

/// Activity entry widget
class ActivityEntry extends StatelessWidget {
  final Map<String, dynamic> entry;

  const ActivityEntry({
    super.key,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    final isSuccess = entry['status'] == 'success';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isSuccess ? Colors.green : Colors.red,
          child: Icon(
            isSuccess ? Icons.check : Icons.error,
            color: Colors.white,
          ),
        ),
        title: Text(
          (entry['tool_name'] as String?) ?? 'Unknown tool',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (entry['params'] != null)
              Text('Params: ${entry['params']}'),
            if (entry['result'] != null)
              Text('Result: ${entry['result']}'),
            Text(
              _formatTimestamp(entry['timestamp'] as int?),
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
          ],
        ),
        trailing: Chip(
          label: Text(
            entry['permission_level'] ?? 'ask',
            style: const TextStyle(fontSize: 10),
          ),
          backgroundColor: Colors.grey[800],
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
