/// Activity log screen
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';

class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activityLog = ref.watch(activityLogProvider);
    final notifier = ref.read(activityLogProvider.notifier);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity Log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => notifier.refresh(),
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => _clearLog(context, ref),
          ),
        ],
      ),
      body: activityLog.isEmpty
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
                final entry = activityLog[index];
                return ActivityEntry(entry: entry);
              },
            ),
    );
  }
  
  void _clearLog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Activity Log'),
        content: const Text('Are you sure you want to clear all activity logs?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              // In production, delete all entries
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
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
          entry['tool_name'] as String?,
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
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
}
