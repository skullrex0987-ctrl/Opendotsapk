/// Tools screen — the nine built-in device tools plus MCP servers.
///
/// The permission model is the important part here. A tool is Allow, Ask, or
/// Block, and "Ask" means a confirmation sheet on every call. Blocking a tool
/// is enforced in the agent loop, not just in this UI, so the model cannot
/// route around it.
///
/// The tools are laid out as a grid because they are scanned, not read: nine
/// rows of equal content is a column of "more", and the grid lets the status
/// of all nine be seen at once. Below the two-column breakpoint it collapses
/// to a single column so nothing is truncated on a narrow phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/log.dart';
import '../../data/services/mcp_service.dart';
import '../../data/services/secure_store.dart';
import '../providers/providers.dart';
import '../widgets/screen_empty_state.dart';
import '../widgets/screen_section_card.dart';

class ToolsScreen extends ConsumerStatefulWidget {
  const ToolsScreen({super.key});

  @override
  ConsumerState<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends ConsumerState<ToolsScreen> {
  @override
  Widget build(BuildContext context) {
    // The permission state is read inside _PermissionGrid, which rebuilds on
    // its own; watching it here as well would rebuild the MCP panel on every
    // permission change for no visible difference.
    final tools = AppConstants.defaultPermissions.keys.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          ScreenSection(
            title: 'Built-in tools',
            subtitle:
                'Runs on this device. Nothing is sent anywhere unless you '
                'switch a tool to Ask or Allow.',
            padding: EdgeInsets.zero,
            child: _PermissionGrid(tools: tools),
          ),
          const SizedBox(height: 20),
          const ScreenSection(
            title: 'MCP servers',
            subtitle:
                'Connect external tools over the Model Context Protocol. '
                'Anything a server exposes becomes available to the agent.',
            padding: EdgeInsets.zero,
            child: McpServersPanel(),
          ),
        ],
      ),
    );
  }
}

/// The two-column tool grid.
///
/// Wrapped rather than a [GridView]: this lives inside the parent [ListView],
/// and nesting a scrollable grid in a scrollable produces an unbounded-height
/// error unless the grid opts out of scrolling entirely. A [Wrap] gives the
/// same column behaviour with no scroll semantics of its own.
class _PermissionGrid extends ConsumerWidget {
  const _PermissionGrid({required this.tools});

  final List<String> tools;

  /// Below this width a two-column grid would truncate the tool names and the
  /// permission dropdown, so it collapses to one column.
  static const double _twoColumnBreakpoint = 420;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(toolPermissionsProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= _twoColumnBreakpoint;
        final gap = 10.0;
        final width = twoColumns
            ? (constraints.maxWidth - gap) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final tool in tools)
              SizedBox(
                width: width,
                child: _ToolCard(
                  tool: tool,
                  level: permissions[tool] ?? AppConstants.permissionAsk,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One tool: name, what it does, and its permission state.
class _ToolCard extends ConsumerWidget {
  const _ToolCard({required this.tool, required this.level});

  final String tool;
  final String level;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // The permission word is the point of this screen, so it owns the colour:
    // green runs freely, amber asks first, red is refused outright.
    final tint = switch (level) {
      AppConstants.permissionAllow => AppColors.success,
      AppConstants.permissionBlock => AppColors.danger,
      _ => AppColors.warning,
    };
    final statusText = switch (level) {
      AppConstants.permissionAllow => 'Runs freely',
      AppConstants.permissionBlock => 'Blocked',
      _ => 'Asks first',
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ScreenRowIcon(icon: _iconFor(tool), color: tint, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _prettyName(tool),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(_describe(tool), style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                // Dot + word rather than colour alone: three of the three
                // states are distinguished by hue and nothing else, which is
                // not enough to read at a glance.
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: tint,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    statusText,
                    style: theme.textTheme.labelMedium?.copyWith(color: tint),
                  ),
                ),
                Flexible(
                  flex: 2,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: level,
                      isDense: true,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(
                          value: AppConstants.permissionAllow,
                          child: Text('Allow'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.permissionAsk,
                          child: Text('Ask'),
                        ),
                        DropdownMenuItem(
                          value: AppConstants.permissionBlock,
                          child: Text('Block'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        ref
                            .read(toolPermissionsProvider.notifier)
                            .setPermission(tool, v);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String tool) {
    switch (tool) {
      case AppConstants.toolSendSms:
        return Icons.sms_outlined;
      case AppConstants.toolCalendarEvent:
        return Icons.event_outlined;
      case AppConstants.toolAddContact:
        return Icons.person_add_alt_1_outlined;
      case AppConstants.toolSetAlarm:
        return Icons.alarm_outlined;
      case AppConstants.toolOpenApp:
        return Icons.apps_outlined;
      case AppConstants.toolWebSearch:
        return Icons.search;
      case AppConstants.toolGetLocation:
        return Icons.location_on_outlined;
      case AppConstants.toolCreateNote:
        return Icons.note_add_outlined;
      case AppConstants.toolReadNotes:
        return Icons.library_books_outlined;
      default:
        return Icons.handyman_outlined;
    }
  }

  static String _prettyName(String tool) => tool
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');

  static String _describe(String tool) {
    switch (tool) {
      case AppConstants.toolSendSms:
        return 'Sends a text message. Costs money and cannot be undone.';
      case AppConstants.toolCalendarEvent:
        return 'Adds an event to your calendar.';
      case AppConstants.toolAddContact:
        return 'Creates a contact entry.';
      case AppConstants.toolSetAlarm:
        return 'Sets an alarm.';
      case AppConstants.toolOpenApp:
        return 'Launches another app by package name.';
      case AppConstants.toolWebSearch:
        return 'Searches the web. This is the only tool that uses the network.';
      case AppConstants.toolGetLocation:
        return 'Reads your current location.';
      case AppConstants.toolCreateNote:
        return 'Saves a local note, encrypted at rest.';
      case AppConstants.toolReadNotes:
        return 'Reads your local notes.';
      default:
        return '';
    }
  }
}

/// Add, remove and connect MCP servers, and list the tools they expose.
class McpServersPanel extends ConsumerStatefulWidget {
  const McpServersPanel({super.key});

  @override
  ConsumerState<McpServersPanel> createState() => _McpServersPanelState();
}

class _McpServersPanelState extends ConsumerState<McpServersPanel> {
  List<McpServerConfig> _servers = [];
  List<McpTool> _tools = [];
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final mcp = ref.read(mcpServiceProvider);
    setState(() {
      _servers = mcp.servers.toList();
      _tools = mcp.allTools;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_servers.isEmpty) {
      return ScreenEmptyState(
        icon: Icons.hub_outlined,
        title: 'No MCP servers connected',
        message:
            'Add one to extend the agent beyond the built-in tools — for '
            'example a filesystem, GitHub or database server.',
        actionLabel: 'Add server',
        actionIcon: Icons.add,
        onAction: _addServer,
        compact: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in _servers) ...[
          _ServerCard(
            server: s,
            toolCount: _tools.where((t) => t.serverId == s.id).length,
            onDelete: () {
              ref.read(mcpServiceProvider).removeServer(s.id);
              _refresh();
            },
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy ? null : _addServer,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add server'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _connectAll,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Connect'),
              ),
            ),
          ],
        ),
        if (_status != null) ...[
          const SizedBox(height: 12),
          _StatusLine(text: _status!),
        ],
        if (_tools.isNotEmpty) ...[
          const SizedBox(height: 16),
          const ScreenRowDivider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Available tools (${_tools.length})',
              style: theme.textTheme.labelLarge,
            ),
          ),
          for (final t in _tools)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: ScreenRowIcon(
                icon: Icons.build_outlined,
                color: AppColors.accent,
                size: 30,
              ),
              title: Text(t.qualifiedName, style: theme.textTheme.bodyMedium),
              subtitle: Text(
                t.description.isEmpty ? '(no description)' : t.description,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ],
    );
  }

  Future<void> _addServer() async {
    final nameCtl = TextEditingController();
    final urlCtl = TextEditingController();
    final tokenCtl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add MCP server'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Filesystem',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlCtl,
                decoration: const InputDecoration(
                  labelText: 'Streamable HTTP URL',
                  hintText: 'https://host/mcp',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: tokenCtl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Bearer token (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    // Read the fields before disposing the controllers: the dialog is gone but
    // the text has to survive long enough to be validated and stored.
    final url = urlCtl.text.trim();
    final name = nameCtl.text.trim();
    final token = tokenCtl.text.trim();

    nameCtl.dispose();
    urlCtl.dispose();
    tokenCtl.dispose();

    if (ok != true || url.isEmpty) return;

    final id = const Uuid().v4().substring(0, 8);

    final mcp = ref.read(mcpServiceProvider);
    mcp.addServer(
      McpServerConfig(
        id: id,
        name: name.isEmpty ? 'Server $id' : name,
        url: url,
        requiresAuth: token.isNotEmpty,
      ),
    );

    // The token is a secret: keep it in the keystore, keyed by server id.
    if (token.isNotEmpty) {
      await SecureStore.instance.setApiKey('mcp.$id', token);
    }

    _refresh();
    await _connectOne(id);
  }

  Future<void> _connectOne(String id) async {
    final mcp = ref.read(mcpServiceProvider);
    final server = mcp.servers.firstWhere((s) => s.id == id);

    setState(() {
      _busy = true;
      _status = 'Connecting to ${server.name}…';
    });

    try {
      final token = server.requiresAuth
          ? await SecureStore.instance.apiKey('mcp.$id')
          : null;
      final tools = await mcp.connect(server, authToken: token);
      if (!mounted) return;
      setState(
        () => _status = 'OK — ${server.name} exposed ${tools.length} tool(s).',
      );
      _refresh();
    } catch (e) {
      Log.w('mcp connect failed: $e');
      if (!mounted) return;
      setState(() => _status = '${server.name}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectAll() async {
    setState(() {
      _busy = true;
      _status = 'Connecting…';
    });

    try {
      final mcp = ref.read(mcpServiceProvider);
      final errors = <String, String>{};
      for (final s in mcp.servers) {
        if (!s.enabled) continue;
        try {
          final token = s.requiresAuth
              ? await SecureStore.instance.apiKey('mcp.${s.id}')
              : null;
          await mcp.connect(s, authToken: token);
        } catch (e) {
          errors[s.id] = '$e';
        }
      }
      if (!mounted) return;
      setState(() {
        _status = errors.isEmpty
            ? 'OK — all servers connected, ${mcp.allTools.length} tool(s) total.'
            : '${errors.length} server(s) failed. '
                  '${mcp.allTools.length} tool(s) available from the rest.';
      });
      _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// One configured MCP server.
class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.toolCount,
    required this.onDelete,
  });

  final McpServerConfig server;
  final int toolCount;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = server.enabled
        ? AppColors.success
        : theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: ScreenRowIcon(
          icon: server.enabled ? Icons.hub : Icons.hub_outlined,
          color: tint,
        ),
        title: Text(server.name),
        subtitle: Text(
          '${server.url}\n$toolCount tool(s)',
          style: theme.textTheme.bodySmall,
        ),
        isThreeLine: true,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Remove server',
          onPressed: onDelete,
        ),
      ),
    );
  }
}

/// The connection result line, coloured by how it went.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = text.startsWith('OK');
    final tint = ok
        ? AppColors.success
        : text.startsWith('Connecting')
        ? AppColors.accent
        : AppColors.danger;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.info_outline,
            size: 15,
            color: tint,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: tint),
            ),
          ),
        ],
      ),
    );
  }
}
