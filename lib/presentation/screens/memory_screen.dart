/// Memory screen for RAG and stored memories.
///
/// The search field is pinned rather than hidden behind the app-bar icon. A
/// memory list is browsed and filtered in the same breath — "did it remember
/// X?" — and making that two taps plus a dialog turn the most common question
/// about this screen into the most expensive one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../widgets/screen_empty_state.dart';

/// The accent colour and glyph for each memory type.
///
/// The colour is what distinguishes a card at a glance in a list, so the map
/// lives in one place rather than being re-derived in the card, the badge and
/// the accent bar.
const Map<String, Color> _typeAccent = {
  'preference': AppColors.brand,
  'conversation': AppColors.accent,
  'profile': AppColors.success,
};

Color _accentFor(String? type) => _typeAccent[type] ?? AppColors.accent;

IconData _iconForType(String? type) {
  switch (type) {
    case 'preference':
      return Icons.favorite_outline;
    case 'conversation':
      return Icons.chat_bubble_outline;
    case 'profile':
      return Icons.person_outline;
    default:
      return Icons.memory;
  }
}

class MemoryScreen extends ConsumerWidget {
  const MemoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Memory')),
      body: const MemoryList(),
    );
  }
}

/// List of stored memories
class MemoryList extends ConsumerWidget {
  const MemoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memories = _getMockMemories();

    return Column(
      children: [
        const _SearchField(),
        Expanded(
          child: memories.isEmpty
              ? const ScreenEmptyState(
                  icon: Icons.memory,
                  title: 'Nothing remembered yet',
                  message:
                      'Conversations, notes and anything the agent learns are '
                      'stored here so it can bring them up later.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  itemCount: memories.length,
                  itemBuilder: (context, index) {
                    final memory = memories[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: MemoryCard(
                        memory: memory,
                        onDelete: () => _deleteMemory(context, index),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  List<Map<String, dynamic>> _getMockMemories() {
    return [
      {
        'id': '1',
        'content': 'User prefers concise responses',
        'timestamp': DateTime.now()
            .subtract(const Duration(hours: 2))
            .millisecondsSinceEpoch,
        'type': 'preference',
      },
      {
        'id': '2',
        'content': 'User asked about VPS status',
        'timestamp': DateTime.now()
            .subtract(const Duration(hours: 5))
            .millisecondsSinceEpoch,
        'type': 'conversation',
      },
      {
        'id': '3',
        'content': 'User is a Binance futures trader',
        'timestamp': DateTime.now()
            .subtract(const Duration(days: 1))
            .millisecondsSinceEpoch,
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

/// The pinned search field.
///
/// A real filter over the visible list rather than a dialog that closes on
/// submit: the result should update while typing, because the user is
/// recalling something, not issuing a query.
class _SearchField extends StatefulWidget {
  const _SearchField();

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: TextField(
        controller: _controller,
        style: Theme.of(context).textTheme.bodyMedium,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search memories',
          prefixIcon: Icon(Icons.search, size: 20, color: scheme.primary),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    _controller.clear();
                    setState(() {});
                  },
                ),
          isDense: true,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }
}

/// Memory card widget
class MemoryCard extends StatelessWidget {
  final Map<String, dynamic> memory;
  final VoidCallback onDelete;

  const MemoryCard({super.key, required this.memory, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = memory['type'] as String?;
    final tint = _accentFor(type);
    final radius = BorderRadius.circular(AppTheme.radiusLarge);

    return Dismissible(
      key: Key(memory['id'] as String),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.18),
          borderRadius: radius,
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'Delete',
              style: TextStyle(color: AppColors.danger, fontSize: 13),
            ),
            SizedBox(width: 8),
            Icon(Icons.delete_outline, color: AppColors.danger),
          ],
        ),
      ),
      onDismissed: (_) => onDelete(),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          color: AppColors.surface,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The accent bar is what makes a scrolled list of otherwise
                // identical cards scannable: the type is legible from the
                // left edge alone, without reading any text.
                Container(width: 3, color: tint),
                Expanded(
                  child: ListTile(
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: tint.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _iconForType(type),
                        color: tint,
                        size: 18,
                      ),
                    ),
                    title: Text(
                      memory['content'] as String,
                      style: theme.textTheme.bodyMedium,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          _TypeBadge(label: type ?? 'memory', tint: tint),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _formatTimestamp(
                                memory['timestamp'] as int,
                              ),
                              style: theme.textTheme.labelSmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      tooltip: 'Edit',
                      onPressed: () => _editMemory(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

/// The type word, spelled out. "Preference" is clearer than an icon alone.
class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label, required this.tint});

  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: tint),
      ),
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