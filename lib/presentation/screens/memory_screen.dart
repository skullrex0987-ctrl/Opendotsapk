/// Memory screen for RAG and stored memories
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_constants.dart';

class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Memory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
        ],
      ),
      body: const MemoryList(),
    );
  }
  
  void _showSearchDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => const MemorySearchDialog(),
    );
  }
}

/// List of stored memories
class MemoryList extends ConsumerWidget {
  const MemoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // In production, fetch from database
    final memories = _getMockMemories();
    
    if (memories.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.memory, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No memories yet',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'Conversations will be stored here',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: memories.length,
      itemBuilder: (context, index) {
        final memory = memories[index];
        return MemoryCard(
          memory: memory,
          onDelete: () => _deleteMemory(context, index),
        );
      },
    );
  }
  
  List<Map<String, dynamic>> _getMockMemories() {
    return [
      {
        'id': '1',
        'content': 'User prefers concise responses',
        'timestamp': DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
        'type': 'preference',
      },
      {
        'id': '2',
        'content': 'User asked about VPS status',
        'timestamp': DateTime.now().subtract(const Duration(hours: 5)).millisecondsSinceEpoch,
        'type': 'conversation',
      },
      {
        'id': '3',
        'content': 'User is a Binance futures trader',
        'timestamp': DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
        'type': 'profile',
      },
    ];
  }
  
  void _deleteMemory(BuildContext context, int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Memory'),
        content: const Text('Are you sure you want to delete this memory?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              // In production, delete from database
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

/// Memory card widget
class MemoryCard extends StatelessWidget {
  final Map<String, dynamic> memory;
  final VoidCallback onDelete;
  
  const MemoryCard({
    super.key,
    required this.memory,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final typeColors = {
      'preference': AppConstants.primaryColor,
      'conversation': Colors.blue,
      'profile': Colors.green,
    };
    
    return Dismissible(
      key: Key(memory['id'] as String),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.red),
      ),
      onDismissed: (_) => onDelete(),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: typeColors[memory['type']] ?? Colors.grey,
            child: Icon(
              _getIconForType(memory['type']),
              color: Colors.white,
              size: 20,
            ),
          ),
          title: Text(memory['content'] as String),
          subtitle: Text(
            _formatTimestamp(memory['timestamp'] as int),
            style: TextStyle(color: Colors.grey[500]),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.edit, size: 20),
            onPressed: () => _editMemory(context),
          ),
        ),
      ),
    );
  }
  
  IconData _getIconForType(String? type) {
    switch (type) {
      case 'preference': return Icons.favorite;
      case 'conversation': return Icons.chat;
      case 'profile': return Icons.person;
      default: return Icons.memory;
    }
  }
  
  String _formatTimestamp(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }
  
  void _editMemory(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => MemoryEditDialog(memory: memory),
    );
  }
}

/// Memory edit dialog
class MemoryEditDialog extends StatefulWidget {
  final Map<String, dynamic> memory;
  
  const MemoryEditDialog({super.key, required this.memory});

  @override
  State<MemoryEditDialog> createState() => _MemoryEditDialogState();
}

class _MemoryEditDialogState extends State<MemoryEditDialog> {
  late TextEditingController _controller;
  
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.memory['content']);
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Memory'),
      content: TextField(
        controller: _controller,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'Edit memory content...',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            // In production, update database
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Search dialog for memories
class MemorySearchDialog extends StatefulWidget {
  const MemorySearchDialog({super.key});

  @override
  State<MemorySearchDialog> createState() => _MemorySearchDialogState();
}

class _MemorySearchDialogState extends State<MemorySearchDialog> {
  final TextEditingController _controller = TextEditingController();
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search Memories'),
      content: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          hintText: 'Search...',
          prefixIcon: Icon(Icons.search),
          border: OutlineInputBorder(),
        ),
        autofocus: true,
        onSubmitted: (_) => Navigator.pop(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            // In production, search in database
            Navigator.pop(context);
          },
          child: const Text('Search'),
        ),
      ],
    );
  }
}
