/// Tools screen — the nine built-in device tools plus MCP servers.
///
/// The permission model is the important part here. A tool is Allow, Ask, or
/// Block, and "Ask" means a confirmation sheet on every call. Blocking a tool
/// is enforced in the agent loop, not just in this UI, so the model cannot
/// route around it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/log.dart';
import '../../data/services/mcp_service.dart';
import '../../data/services/secure_store.dart';
import '../providers/providers.dart';

class ToolsScreen extends ConsumerStatefulWidget {
  const ToolsScreen({super.key});

  @override
  ConsumerState<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends ConsumerState<ToolsScreen> {
  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(toolPermissionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tools')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader(
            title: 'Built-in tools',
            subtitle: 'Runs on this device. Nothing is sent anywhere.',
          ),
          for (final entry in AppConstants.defaultPermissions.keys)
            _permissionTile(entry, permissions[entry] ?? 'ask'),

          const SizedBox(height: 24),

          const _SectionHeader(
            title: 'MCP servers',
            subtitle: 'Connect external tools over the Model Context Protocol. '
                'Anything a server exposes becomes available to the agent.',
          ),
          const McpServersPanel(),
        ],
      ),
    );
  }

  Widget _permissionTile(String toolName, String level) {
    return Card(
      child: ListTile(
        title: Text(_prettyName(toolName)),
        subtitle: Text(
          _describe(toolName),
          style: const TextStyle(fontSize: 11),
        ),
        trailing: DropdownButton<String>(
          value: level,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(
              value: AppConstants.permissionAllow,
              child: Text('Allow', style: TextStyle(color: Colors.green)),
            ),
            DropdownMenuItem(
              value: AppConstants.permissionAsk,
              child: Text('Ask', style: TextStyle(color: Colors.orange)),
            ),
            DropdownMenuItem(
              value: AppConstants.permissionBlock,
              child: Text('Block', style: TextStyle(color: Colors.red)),
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            ref.read(toolPermissionsProvider.notifier).setPermission(toolName, v);
          },
        ),
      ),
    );
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

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: Colors.grey[400])),
          const SizedBox(height: 8),
        ],
      ),
    );
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_servers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No servers configured. Add one to extend the agent beyond the '
              'built-in tools — for example a filesystem, GitHub or database '
              'server.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ),
        for (final s in _servers)
          Card(
            child: ListTile(
              leading: Icon(
                s.enabled ? Icons.hub : Icons.hub_outlined,
                color: s.enabled ? Colors.green : Colors.grey,
              ),
              title: Text(s.name),
              subtitle: Text(
                '${s.url}\n'
                '${_tools.where((t) => t.serverId == s.id).length} tool(s)',
                style: const TextStyle(fontSize: 11),
              ),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  ref.read(mcpServiceProvider).removeServer(s.id);
                  _refresh();
                },
              ),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _addServer,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add server'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy || _servers.isEmpty ? null : _connectAll,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Connect'),
            ),
          ],
        ),
        if (_status != null) ...[
          const SizedBox(height: 10),
          Text(_status!,
              style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ],
        if (_tools.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Available tools (${_tools.length})',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          for (final t in _tools)
            ListTile(
              dense: true,
              leading: const Icon(Icons.build_outlined, size: 18),
              title: Text(t.qualifiedName,
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                t.description.isEmpty ? '(no description)' : t.description,
                style: const TextStyle(fontSize: 11),
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    final url = urlCtl.text.trim();
    if (url.isEmpty) return;

    final id = const Uuid().v4().substring(0, 8);
    final token = tokenCtl.text.trim();

    final mcp = ref.read(mcpServiceProvider);
    mcp.addServer(McpServerConfig(
      id: id,
      name: nameCtl.text.trim().isEmpty ? 'Server $id' : nameCtl.text.trim(),
      url: url,
      requiresAuth: token.isNotEmpty,
    ));

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
      setState(() => _status =
          'OK — ${server.name} exposed ${tools.length} tool(s).');
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
