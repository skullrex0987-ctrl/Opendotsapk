/// Cloud model settings — bring-your-own-key.
///
/// Design rules this screen follows:
///  * The key field is write-only. A saved key is shown as "saved", never
///    echoed back, because reading it into a widget risks it reaching a
///    screenshot or a crash report.
///  * "Test" makes one minimal request so the user finds out now rather than
///    mid-conversation.
///  * The routing mode is explained in plain words, not jargon.
///
/// The screen opens by putting the product's central claim on screen before
/// any provider list: on-device is free and private, cloud needs your key and
/// is opt-in. Every screen below that is a detail of one of those two halves.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/log.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/router_service.dart';
import '../../data/services/secure_store.dart';
import '../../domain/models/cloud_provider.dart';
import '../providers/providers.dart';
import '../widgets/screen_section_card.dart';

/// True when [host] names this device or the local network, so that a
/// plaintext `http://` request to it cannot be read off the public internet.
///
/// Covers loopback (`localhost`, `127.0.0.0/8`, `::1`), the RFC1918 private
/// ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`), the link-local
/// range (`169.254.0.0/16`) and mDNS `.local` names. The emulator host
/// `10.0.2.2` falls inside `10.0.0.0/8` and is therefore allowed too.
///
/// This is the app-level half of the cleartext policy. Android's
/// network_security_config can only whitelist named hosts, not CIDR ranges, so
/// the private IP-literal ranges are enforced here and not there.
///
/// A pure function of its string argument, so it can be unit-tested without a
/// widget or an Android host.
bool isLocalHost(String host) {
  var h = host.trim().toLowerCase();
  // Uri.host already strips the brackets from an IPv6 literal; be defensive.
  if (h.length > 1 && h.startsWith('[') && h.endsWith(']')) {
    h = h.substring(1, h.length - 1);
  }
  if (h == 'localhost' || h == '::1') return true;
  if (h.endsWith('.local')) return true; // mDNS, e.g. mybox.local

  final octets = _parseIpv4(h);
  if (octets == null) return false;
  final a = octets[0];
  final b = octets[1];
  if (a == 127) return true; // 127.0.0.0/8 loopback
  if (a == 10) return true; // 10.0.0.0/8
  if (a == 192 && b == 168) return true; // 192.168.0.0/16
  if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
  if (a == 169 && b == 254) return true; // 169.254.0.0/16 link-local
  return false;
}

/// True only for a plaintext `http://` URL whose host is local (see
/// [isLocalHost]). Every other input — https, http to a public host, or
/// malformed — returns false.
///
/// Exposed as a pure function so the allowlist rule can be unit-tested later
/// without a widget test.
bool isLocalHttpHostAllowed(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'http') return false;
  return isLocalHost(uri.host);
}

/// Validates a base-URL field value. Returns null when it may be stored, or a
/// message explaining why it may not.
///
/// An empty value is allowed: it means "use the provider default". `https` is
/// always allowed. `http` is allowed only for local hosts, because an API key
/// or prompt sent over plaintext http to a public host can be read on the
/// network. This is the guard that stops a user from turning a public endpoint
/// into a cleartext one.
String? baseUrlValidationError(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return 'Enter a full URL including the scheme, e.g. https://host/v1.';
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') return null;
  if (scheme != 'http') return 'Only http and https URLs are supported.';
  if (isLocalHost(uri.host)) return null;
  return 'Plaintext http:// is allowed only for a local endpoint. Use '
      'https:// — an API key sent over http could be read on the network.';
}

/// Splits a dotted-decimal IPv4 string into four octets, or null if it is not a
/// well-formed IPv4 literal. Kept private; only [isLocalHost] uses it.
List<int>? _parseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final part in parts) {
    if (part.isEmpty) return null;
    final n = int.tryParse(part);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _privacyCard(),
          const SizedBox(height: 20),
          _routingCard(settings),
          const SizedBox(height: 20),
          ScreenSection(
            title: 'Providers',
            subtitle:
                'Each one needs its own key, stored in this device\'s '
                'keystore. Nothing is sent until you add one.',
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < CloudCatalog.providers.length; i++) ...[
                  _providerTile(
                    CloudCatalog.providers[i],
                    activeProvider == CloudCatalog.providers[i].id,
                  ),
                  if (i != CloudCatalog.providers.length - 1)
                    const ScreenRowDivider(),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          _usageCard(),
        ],
      ),
    );
  }

  Widget _privacyCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ScreenRowIcon(
                  icon: Icons.lock_outline,
                  color: AppColors.success,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Where your data goes',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // The two halves of the product, side by side. This is the one
            // place on the screen where the comparison has to be explicit:
            // everything below it is configuration for the right-hand column.
            // IntrinsicHeight is what makes the two cards equal height. A Row
            // with CrossAxisAlignment.stretch inside a Column has an unbounded
            // height constraint and would throw; IntrinsicHeight supplies a
            // finite one derived from the taller child.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(child: _ModeCard(local: true)),
                  const SizedBox(width: 10),
                  const Expanded(child: _ModeCard(local: false)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'You supply your own API key. It is stored in this device\'s '
              'hardware keystore and sent only to the provider you chose.\n\n'
              'There is no LocalMind server. Your key is never uploaded, and '
              'the on-device model stays the default — cloud is used only when '
              'you ask for it or when the router decides a turn needs it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _routingCard(Map<String, dynamic> settings) {
    final mode = '${settings['cloud_mode'] ?? 'auto'}';
    final private = settings['private_mode'] as bool? ?? false;

    return ScreenSection(
      title: 'Routing',
      subtitle: _modeExplanation(mode),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: private,
            onChanged: (v) => ref
                .read(settingsProvider.notifier)
                .updateSetting('private_mode', v),
            title: const Text('Private mode'),
            subtitle: const Text(
              'Forbid all network use. Nothing leaves this device, ever.',
            ),
          ),
        ],
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
        final ready = hasKey || keyOptional;

        return ListTile(
          leading: ScreenRowIcon(
            icon: _providerIcon(provider.id),
            color: ready ? AppColors.success : null,
          ),
          title: Row(
            children: [
              Expanded(child: Text(provider.displayName)),
              if (isActive) const _ActiveChip(),
            ],
          ),
          subtitle: Text(
            hasKey
                ? 'Key saved · ${provider.models.length} model(s)'
                : keyOptional
                ? 'No key needed · ${provider.models.length} model(s)'
                : 'No key yet',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            AppPageRoute(builder: (_) => CloudProviderScreen(provider: provider)),
          ),
        );
      },
    );
  }

  /// A Material glyph standing in for a provider's logo.
  ///
  /// No network images: an icon is available offline, never shifts layout, and
  /// cannot fail to load on a screen whose whole point is working without a
  /// connection.
  static IconData _providerIcon(String id) {
    switch (id) {
      case 'openai':
        return Icons.blur_on;
      case 'anthropic':
        return Icons.auto_awesome;
      case 'gemini':
        return Icons.diamond_outlined;
      case 'groq':
        return Icons.bolt;
      case 'deepseek':
        return Icons.waves;
      case 'openrouter':
        return Icons.hub_outlined;
      case 'ollama':
        return Icons.dns_outlined;
      default:
        return Icons.settings_ethernet;
    }
  }

  Widget _usageCard() {
    final cloud = ref.read(cloudServiceProvider);

    return ScreenSection(
      title: 'This session',
      subtitle: 'Estimated from published list prices.',
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _UsageRow(
            label: 'Prompt tokens',
            value: '${cloud.sessionPromptTokens}',
          ),
          _UsageRow(
            label: 'Completion tokens',
            value: '${cloud.sessionCompletionTokens}',
          ),
          _UsageRow(
            label: 'Estimated cost',
            value: '\$${cloud.sessionCostUsd.toStringAsFixed(4)}',
            highlight: true,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(cloud.resetSessionUsage),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The on-device / cloud contrast at the top of the screen.
class _ModeCard extends StatelessWidget {
  const _ModeCard({required this.local});

  final bool local;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = local ? AppColors.success : AppColors.accent;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        border: Border.all(color: tint.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            local ? Icons.phone_android : Icons.cloud_outlined,
            size: 20,
            color: tint,
          ),
          const SizedBox(height: 8),
          Text(
            local ? 'On-device' : 'Cloud',
            style: theme.textTheme.titleMedium?.copyWith(color: tint),
          ),
          const SizedBox(height: 4),
          Text(
            local ? 'Free and private. Works offline.' : 'Needs your API key. '
                'You are billed.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// "active" pill on the selected provider.
class _ActiveChip extends StatelessWidget {
  const _ActiveChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
      ),
      child: Text(
        'active',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: AppColors.success),
      ),
    );
  }
}

/// One line of session usage.
class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: highlight ? AppColors.accent : null,
              fontWeight: highlight ? FontWeight.w600 : null,
            ),
          ),
        ],
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

    // Live base-URL validation, recomputed on every keystroke (the field's
    // onChanged calls setState). An empty value means "provider default".
    final baseUrlText = _baseUrlController.text.trim();
    final baseUrlError = baseUrlValidationError(baseUrlText);
    final showsLocalHttpWarning =
        baseUrlError == null && isLocalHttpHostAllowed(baseUrlText);

    return Scaffold(
      appBar: AppBar(title: Text(widget.provider.displayName)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _keyCard(),
          if (widget.provider.id == 'custom' ||
              widget.provider.id == 'ollama') ...[
            const SizedBox(height: 20),
            _baseUrlCard(
              baseUrlText: baseUrlText,
              baseUrlError: baseUrlError,
              showsLocalHttpWarning: showsLocalHttpWarning,
            ),
          ],
          const SizedBox(height: 20),
          ScreenSection(
            title: 'Model',
            subtitle: 'Which of this provider\'s models answers cloud turns.',
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < widget.provider.models.length; i++) ...[
                  _modelTile(widget.provider.models[i], activeModel),
                  if (i != widget.provider.models.length - 1)
                    const ScreenRowDivider(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyCard() {
    final theme = Theme.of(context);

    return ScreenSection(
      title: _hasKey ? 'API key saved' : 'API key',
      subtitle: _hasKey
          ? 'A key is stored in the keystore. It is never displayed. Paste a '
                'new one below to replace it, or remove it.'
          : 'Stored in this device\'s hardware keystore and sent only to '
                '${widget.provider.displayName}.',
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_hasKey)
            TextField(
              controller: _keyController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: widget.provider.keyHint.isNotEmpty
                    ? 'Starts with ${widget.provider.keyHint}'
                    : 'Paste your API key',
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!_hasKey)
                FilledButton.icon(
                  onPressed: _busy ? null : _saveKey,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save key'),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _test,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('Test connection'),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _removeKey,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove'),
                ),
              ],
            ],
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(
              _status!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _status!.startsWith('OK')
                    ? AppColors.success
                    : AppColors.warning,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _baseUrlCard({
    required String baseUrlText,
    required String? baseUrlError,
    required bool showsLocalHttpWarning,
  }) {
    return ScreenSection(
      title: 'Base URL',
      subtitle: 'For a LAN server this must be reachable from the phone.',
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _baseUrlController,
            onChanged: (_) => setState(() {}),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'https://host/v1',
              errorText: baseUrlError,
              errorMaxLines: 3,
            ),
          ),
          if (showsLocalHttpWarning) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: AppColors.warning,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Local http:// endpoint. Traffic to this host is '
                    'not encrypted, but it stays on your network. '
                    'Anything off this network must use https://.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: baseUrlError == null ? _saveBaseUrl : null,
              child: const Text('Save URL'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelTile(CloudModel model, String? activeModel) {
    final theme = Theme.of(context);

    return RadioListTile<String>(
      value: model.id,
      groupValue: activeModel,
      onChanged: (v) => _selectModel(model),
      title: Text(model.displayName),
      subtitle: Text(
        '${model.contextTokens ~/ 1000}k context'
        '${model.supportsVision ? ' · vision' : ''}'
        '${model.inputPricePerM > 0 ? ' · ~\$${model.inputPricePerM}/M in' : ''}',
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  Future<void> _saveKey() async {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;

    // (d) Never store a key that would be sent to a plaintext, non-local
    // endpoint. The base URL in force is exactly where this key will go, so
    // validate it before anything is written to the keystore.
    final baseUrl = await _effectiveBaseUrl();
    if (!mounted) return;
    final urlError = baseUrlValidationError(baseUrl);
    if (urlError != null) {
      setState(() => _status = 'Key not saved. $urlError');
      return;
    }

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
            FilledButton(
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
    final url = _baseUrlController.text.trim();
    // Belt-and-braces: the Save button is already disabled while the field is
    // invalid, but never persist a URL that failed validation.
    final error = baseUrlValidationError(url);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final cfg = Map<String, String>.from(
      await SecureStore.instance.providerConfig(widget.provider.id),
    );
    cfg['baseUrl'] = url;
    await SecureStore.instance.setProviderConfig(widget.provider.id, cfg);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Base URL saved.')));
    _refreshRouter();
  }

  /// The base URL the provider will actually be dialed at: whatever is typed
  /// in the field now, else the saved config, else the provider default. Used
  /// to validate that a key is not about to be sent in the clear.
  Future<String> _effectiveBaseUrl() async {
    final typed = _baseUrlController.text.trim();
    if (typed.isNotEmpty) return typed;
    final cfg = await SecureStore.instance.providerConfig(widget.provider.id);
    return cfg['baseUrl'] ?? widget.provider.defaultBaseUrl;
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
      setState(
        () => _status = reply.isEmpty
            ? 'The provider replied but sent no text. The key works, though.'
            : 'OK — the model replied: "$reply"',
      );
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
        content: Text(
          '${widget.provider.displayName} ${model.displayName} '
          'is now the cloud model.',
        ),
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