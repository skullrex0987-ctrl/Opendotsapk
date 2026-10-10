/// Cloud model settings — bring-your-own-key.
///
/// Design rules this screen follows:
///  * The key field is write-only. A saved key is shown as "saved", never
///    echoed back, because reading it into a widget risks it reaching a
///    screenshot or a crash report.
///  * "Test" makes one minimal request so the user finds out now rather than
///    mid-conversation.
///  * The routing mode is explained in plain words, not jargon.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/log.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/router_service.dart';
import '../../data/services/secure_store.dart';
import '../../domain/models/cloud_provider.dart';
import '../providers/providers.dart';

class CloudModelsScreen extends ConsumerStatefulWidget {
  const CloudModelsScreen({super.key});

  @override
  ConsumerState<CloudModelsScreen> createState() => _CloudModelsScreenState();
}

class _CloudModelsScreenState extends ConsumerState<CloudModelsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final activeProvider = settings['active_cloud_provider'] as String?;

    return Scaffold(
      appBar: AppBar(title: const Text('Cloud Models')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _privacyCard(),
          const SizedBox(height: 16),
          _routingCard(settings),
          const SizedBox(height: 16),
          const Text('Providers',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final p in CloudCatalog.providers)
            _providerTile(p, activeProvider == p.id),
          const SizedBox(height: 24),
          _usageCard(),
        ],
      ),
    );
  }

  Widget _privacyCard() {
    return Card(
      color: Colors.green.withOpacity(0.08),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, size: 18, color: Colors.green[400]),
                const SizedBox(width: 8),
                const Text('How this works',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'You supply your own API key. It is stored in this device\'s '
              'hardware keystore and sent only to the provider you chose.\n\n'
              'There is no LocalMind server. Your key is never uploaded, and '
              'the on-device model stays the default — cloud is used only when '
              'you ask for it or when the router decides a turn needs it.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _routingCard(Map<String, dynamic> settings) {
    final mode = '${settings['cloud_mode'] ?? 'auto'}';
    final private = settings['private_mode'] as bool? ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Routing',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'local', label: Text('On-device')),
                ButtonSegment(value: 'auto', label: Text('Auto')),
                ButtonSegment(value: 'cloud', label: Text('Cloud')),
              ],
              selected: {mode},
              onSelectionChanged: (s) => ref
                  .read(settingsProvider.notifier)
                  .updateSetting('cloud_mode', s.first),
            ),
            const SizedBox(height: 8),
            Text(
              _modeExplanation(mode),
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
            const Divider(height: 24),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: private,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .updateSetting('private_mode', v),
              title: const Text('Private mode'),
              subtitle: const Text(
                'Forbid all network use. Nothing leaves this device, ever.',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _modeExplanation(String mode) {
    switch (mode) {
      case 'local':
        return 'Only the on-device model is used. Cloud is never contacted, '
            'even if a key is saved.';
      case 'cloud':
        return 'Every turn goes to the cloud provider, except when private '
            'mode is on or you are offline.';
      default:
        return 'Short and personal turns stay on-device; long, code-heavy or '
            'explicitly hard questions go to the cloud. Images use a cloud '
            'model when no on-device vision model is loaded.';
    }
  }

  Widget _providerTile(CloudProvider provider, bool isActive) {
    return FutureBuilder<bool>(
      future: SecureStore.instance.hasApiKey(provider.id),
      builder: (context, snap) {
        final hasKey = snap.data ?? false;
        final keyOptional = CloudCatalog.keyOptional.contains(provider.id);

        return Card(
          child: ListTile(
            leading: Icon(
              hasKey || keyOptional ? Icons.check_circle : Icons.key_off,
              color: hasKey || keyOptional ? Colors.green : Colors.grey,
            ),
            title: Row(
              children: [
                Expanded(child: Text(provider.displayName)),
                if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('active',
                        style: TextStyle(fontSize: 10)),
                  ),
              ],
            ),
            subtitle: Text(
              hasKey
                  ? 'Key saved · ${provider.models.length} model(s)'
                  : keyOptional
                      ? 'No key needed · ${provider.models.length} model(s)'
                      : 'No key yet',
              style: const TextStyle(fontSize: 11),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CloudProviderScreen(provider: provider),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _usageCard() {
    final cloud = ref.read(cloudServiceProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This session',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Prompt tokens: ${cloud.sessionPromptTokens}'),
            Text('Completion tokens: ${cloud.sessionCompletionTokens}'),
            Text(
              'Estimated cost: \$${cloud.sessionCostUsd.toStringAsFixed(4)}',
            ),
            const SizedBox(height: 6),
            Text(
              'Cost is computed from published list prices and is an estimate '
              'only. Your provider bills you directly.',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(cloud.resetSessionUsage),
                child: const Text('Reset'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Configure one provider: key, base URL, model choice.
class CloudProviderScreen extends ConsumerStatefulWidget {
  final CloudProvider provider;

  const CloudProviderScreen({super.key, required this.provider});

  @override
  ConsumerState<CloudProviderScreen> createState() =>
      _CloudProviderScreenState();
}

class _CloudProviderScreenState extends ConsumerState<CloudProviderScreen> {
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _baseUrlController = TextEditingController();

  bool _hasKey = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final has = await SecureStore.instance.hasApiKey(widget.provider.id);
    final cfg = await SecureStore.instance.providerConfig(widget.provider.id);
    if (!mounted) return;
    setState(() {
      _hasKey = has;
      _baseUrlController.text =
          cfg['baseUrl'] ?? widget.provider.defaultBaseUrl;
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final isActive = settings['active_cloud_provider'] == widget.provider.id;
    final activeModel = isActive
        ? settings['active_cloud_model'] as String?
        : null;

    return Scaffold(
      appBar: AppBar(title: Text(widget.provider.displayName)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _hasKey ? 'API key saved' : 'API key',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_hasKey)
                    const Text(
                      'A key is stored in the keystore. It is never displayed. '
                      'Paste a new one below to replace it, or remove it.',
                      style: TextStyle(fontSize: 12),
                    )
                  else
                    TextField(
                      controller: _keyController,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        hintText: widget.provider.keyHint.isNotEmpty
                            ? 'Starts with ${widget.provider.keyHint}'
                            : 'Paste your API key',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (!_hasKey)
                        FilledButton(
                          onPressed: _busy ? null : _saveKey,
                          child: const Text('Save key'),
                        )
                      else ...[
                        OutlinedButton(
                          onPressed: _busy ? null : _test,
                          child: const Text('Test connection'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _busy ? null : _removeKey,
                          child: const Text('Remove'),
                        ),
                      ],
                    ],
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _status!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _status!.startsWith('OK')
                            ? Colors.green[300]
                            : Colors.orange[300],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          if (widget.provider.id == 'custom' ||
              widget.provider.id == 'ollama') ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Base URL',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _baseUrlController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'https://host/v1',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'For a LAN server this must be reachable from the phone.',
                      style: TextStyle(fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _saveBaseUrl,
                        child: const Text('Save URL'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],

          const Text('Model', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final m in widget.provider.models)
            Card(
              child: RadioListTile<String>(
                value: m.id,
                groupValue: activeModel,
                onChanged: (v) => _selectModel(m),
                title: Text(m.displayName),
                subtitle: Text(
                  '${m.contextTokens ~/ 1000}k context'
                  '${m.supportsVision ? ' · vision' : ''}'
                  '${m.inputPricePerM > 0 ? ' · ~\$${m.inputPricePerM}/M in' : ''}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;

    // Catch the most common mistake: pasting the wrong provider's key.
    final hint = widget.provider.keyHint;
    if (hint.isNotEmpty && !key.startsWith(hint)) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('That key looks unusual'),
          content: Text(
            '${widget.provider.displayName} keys normally start with "$hint", '
            'but this one does not.\n\nSave it anyway?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save anyway'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await SecureStore.instance.setApiKey(widget.provider.id, key);
      _keyController.clear();
      if (!mounted) return;
      setState(() {
        _hasKey = true;
        _status = 'OK — key saved to the keystore.';
      });
      _refreshRouter();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Could not save the key: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeKey() async {
    await SecureStore.instance.deleteApiKey(widget.provider.id);
    if (!mounted) return;
    setState(() {
      _hasKey = false;
      _status = 'Key removed.';
    });
    _refreshRouter();
  }

  Future<void> _saveBaseUrl() async {
    final cfg = Map<String, String>.from(
      await SecureStore.instance.providerConfig(widget.provider.id),
    );
    cfg['baseUrl'] = _baseUrlController.text.trim();
    await SecureStore.instance.setProviderConfig(widget.provider.id, cfg);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Base URL saved.')),
    );
    _refreshRouter();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = 'Testing…';
    });
    try {
      final reply = await CloudService.instance.testConnection(
        provider: widget.provider,
        modelId: widget.provider.defaultModel.id,
      );
      if (!mounted) return;
      setState(() => _status = reply.isEmpty
          ? 'The provider replied but sent no text. The key works, though.'
          : 'OK — the model replied: "$reply"');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectModel(CloudModel model) async {
    final notifier = ref.read(settingsProvider.notifier);
    await notifier.updateSetting('active_cloud_provider', widget.provider.id);
    await notifier.updateSetting('active_cloud_model', model.id);
    _refreshRouter();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.provider.displayName} ${model.displayName} '
            'is now the cloud model.'),
      ),
    );
  }

  /// Push the saved providers into the router so its decisions reflect reality.
  Future<void> _refreshRouter() async {
    final candidates = <({CloudProvider provider, String modelId})>[];
    for (final p in CloudCatalog.providers) {
      final has = await SecureStore.instance.hasApiKey(p.id);
      if (!has && !CloudCatalog.keyOptional.contains(p.id)) continue;

      final cfg = await SecureStore.instance.providerConfig(p.id);
      final modelId = cfg['model'] ?? p.defaultModel.id;
      candidates.add((provider: p, modelId: modelId));
    }
    RouterService.instance.setCandidates(candidates);
    Log.i('cloud: router now has ${candidates.length} candidate(s)');
  }
}
