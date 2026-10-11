/// Settings screen
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/providers.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/log.dart';
import '../../data/database/database_helper.dart';
import '../../data/services/secure_store.dart';
import '../../domain/models/cloud_provider.dart';
import 'models_screen.dart';
import 'performance_screen.dart';
import 'cloud_screen.dart';
import 'onboarding_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final permissions = ref.watch(toolPermissionsProvider);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Model Management — the real chooser/downloader.
          const SectionTitle(title: 'Models'),
          const ModelsTile(),

          const Divider(),

          // Tool Permissions
          const SectionTitle(title: 'Tool Permissions'),
          PermissionList(permissions: permissions),
          
          const Divider(),
          
          // Personality
          const SectionTitle(title: 'Personality'),
          PersonalitySelector(current: settings['personality'] as String?),
          
          const Divider(),
          
          // Voice Settings
          const SectionTitle(title: 'Voice'),
          VoiceSettings(),
          
          const Divider(),
          
          // Context Size
          const SectionTitle(title: 'Context'),
          ContextSizeSelector(current: settings['context_size'] as int?),
          
          const Divider(),

          // Cloud privacy — the one-time opt-in, and where to withdraw it.
          const SectionTitle(title: 'Privacy'),
          const CloudPrivacySection(),

          const Divider(),

          // Destructive: erase everything and return to first run.
          const SectionTitle(title: 'Data'),
          const EraseDataSection(),

          const Divider(),
          
          // About
          const SectionTitle(title: 'About'),
          const AboutSection(),
        ],
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String title;
  
  const SectionTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.grey[400],
        ),
      ),
    );
  }
}

/// Entry point into the Models chooser/downloader.
class ModelsTile extends ConsumerWidget {
  const ModelsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final llmService = ref.read(llmServiceProvider);

    return ListTile(
      leading: const Icon(Icons.model_training),
      title: const Text('Download and select models'),
      subtitle: Text(
        llmService.isLoaded
            ? 'Loaded: ${llmService.modelPath}'
            : 'No model loaded',
      ),
      trailing: llmService.isLoaded
          ? const Icon(Icons.check_circle, color: Colors.green)
          : const Icon(Icons.warning, color: Colors.orange),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ModelsScreen()),
      ),
    );
  }
}

/// Permission list widget
class PermissionList extends ConsumerWidget {
  final Map<String, String> permissions;
  
  const PermissionList({super.key, required this.permissions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: AppConstants.defaultPermissions.keys.map((tool) {
        final current = permissions[tool] ?? 'ask';
        return ListTile(
          leading: _getToolIcon(tool),
          title: Text(_getToolName(tool)),
          subtitle: Text('Permission: $current'),
          trailing: PopupMenuButton<String>(
            initialValue: current,
            onSelected: (value) {
              ref.read(toolPermissionsProvider.notifier).setPermission(tool, value);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'allow', child: Text('Allow')),
              const PopupMenuItem(value: 'ask', child: Text('Ask')),
              const PopupMenuItem(value: 'block', child: Text('Block')),
            ],
          ),
        );
      }).toList(),
    );
  }
  
  Widget _getToolIcon(String tool) {
    // `ListTile.leading` takes a Widget, not an IconData.
    switch (tool) {
      case 'send_sms': return const Icon(Icons.sms);
      case 'create_calendar_event': return const Icon(Icons.event);
      case 'add_contact': return const Icon(Icons.person_add);
      case 'set_alarm': return const Icon(Icons.alarm);
      case 'open_app': return const Icon(Icons.apps);
      case 'web_search': return const Icon(Icons.search);
      case 'get_location': return const Icon(Icons.location_on);
      case 'create_note': return const Icon(Icons.note);
      case 'read_notes': return const Icon(Icons.library_books);
      default: return const Icon(Icons.handyman);
    }
  }
  
  String _getToolName(String tool) {
    switch (tool) {
      case 'send_sms': return 'Send SMS';
      case 'create_calendar_event': return 'Calendar Event';
      case 'add_contact': return 'Add Contact';
      case 'set_alarm': return 'Set Alarm';
      case 'open_app': return 'Open App';
      case 'web_search': return 'Web Search';
      case 'get_location': return 'Get Location';
      case 'create_note': return 'Create Note';
      case 'read_notes': return 'Read Notes';
      default: return tool;
    }
  }
}

/// Personality selector widget
class PersonalitySelector extends ConsumerWidget {
  final String? current;
  
  const PersonalitySelector({super.key, this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: AppConstants.personalities.keys.map((personality) {
        return RadioListTile<String>(
          title: Text(personality.capitalize()),
          value: personality,
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(settingsProvider.notifier).updateSetting('personality', value);
            }
          },
        );
      }).toList(),
    );
  }
}

/// Voice settings widget
class VoiceSettings extends ConsumerWidget {
  const VoiceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final ttsEnabled = settings['tts_enabled'] as bool? ?? true;
    
    return SwitchListTile(
      title: const Text('Text-to-Speech'),
      subtitle: const Text('Read responses aloud'),
      value: ttsEnabled,
      onChanged: (value) {
        ref.read(settingsProvider.notifier).updateSetting('tts_enabled', value);
      },
    );
  }
}

/// Context size selector widget
class ContextSizeSelector extends ConsumerWidget {
  final int? current;
  
  const ContextSizeSelector({super.key, this.current});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: AppConstants.contextSizes.map((size) {
        return RadioListTile<int>(
          title: Text('$size tokens'),
          value: size,
          groupValue: current,
          onChanged: (value) {
            if (value != null) {
              ref.read(settingsProvider.notifier).updateSetting('context_size', value);
            }
          },
        );
      }).toList(),
    );
  }
}

/// About section widget
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.speed),
          title: const Text('Performance'),
          subtitle: const Text(
            'Backend, chipset and a throughput benchmark',
            style: TextStyle(fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const PerformanceScreen(),
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_queue),
          title: const Text('Cloud Models'),
          subtitle: const Text(
            'Bring your own API key — optional, off by default',
            style: TextStyle(fontSize: 11),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const CloudModelsScreen(),
            ),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.info),
          title: const Text('Version'),
          subtitle: const Text(AppConstants.appVersion),
        ),
        ListTile(
          leading: const Icon(Icons.public),
          title: const Text('License'),
          subtitle: const Text('MIT License'),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'LocalMind - Privacy-first AI Agent',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      ],
    );
  }
}

/// One-time cloud consent.
///
/// Names the destination provider and states exactly what leaves the device.
/// The opt-in is recorded against a specific provider id, so it is shown once
/// per destination and again if the user switches to a different one.
class CloudPrivacySection extends ConsumerWidget {
  const CloudPrivacySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final providerId = settings['active_cloud_provider'] as String?;
    final provider = providerId == null ? null : CloudCatalog.byId(providerId);
    final granted = cloudConsentGranted(settings, providerId);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(granted ? Icons.cloud_done : Icons.cloud_off, size: 18),
                const SizedBox(width: 8),
                const Text('Cloud use',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            if (provider == null)
              const Text(
                'No cloud provider is selected, so nothing is ever sent off '
                'this device. To allow cloud use, add a provider under Cloud '
                'Models; you will be asked to confirm exactly what is shared '
                'before the first request.',
                style: TextStyle(fontSize: 12, height: 1.4),
              )
            else ...[
              Text(
                granted
                    ? 'Cloud is enabled for ${provider.displayName}.'
                    : 'Cloud is off for ${provider.displayName}. Nothing is '
                        'sent until you confirm.',
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 10),
              if (!granted)
                FilledButton(
                  onPressed: () => _confirmConsent(context, ref, provider),
                  child: Text('Enable cloud for ${provider.displayName}'),
                )
              else
                OutlinedButton(
                  onPressed: () {
                    ref
                        .read(settingsProvider.notifier)
                        .revokeCloudConsent();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Cloud consent withdrawn.')),
                    );
                  },
                  child: const Text('Withdraw consent'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Show the single opt-in dialog and persist consent on agreement.
  Future<void> _confirmConsent(
    BuildContext context,
    WidgetRef ref,
    CloudProvider provider,
  ) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Send data to ${provider.displayName}?'),
        content: SingleChildScrollView(
          child: Text(
            CloudPrivacy.consentBody(provider.displayName),
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I agree'),
          ),
        ],
      ),
    );

    if (agreed != true) return;
    await ref.read(settingsProvider.notifier).grantCloudConsent(provider.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cloud enabled for ${provider.displayName}.')),
    );
  }
}

/// "Erase all data" — two-step confirmation, then a full wipe.
///
/// The second confirmation is a real second step (a separate dialog that only
/// accepts once the first has been given, guarded by [TwoStepConfirm]), not a
/// single dialog with two buttons.
class EraseDataSection extends ConsumerStatefulWidget {
  const EraseDataSection({super.key});

  @override
  ConsumerState<EraseDataSection> createState() => _EraseDataSectionState();
}

class _EraseDataSectionState extends ConsumerState<EraseDataSection> {
  final TwoStepConfirm _confirm = TwoStepConfirm();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: _busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.delete_forever, color: Colors.redAccent),
        title: const Text('Erase all data'),
        subtitle: const Text(
          'Delete chat history, memories, notes, documents, API keys and '
          'settings, and return to first run.',
          style: TextStyle(fontSize: 11),
        ),
        enabled: !_busy,
        onTap: _startErase,
      ),
    );
  }

  Future<void> _startErase() async {
    // ---- Step 1: what will be erased ------------------------------------
    final first = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Erase all data?'),
        content: const Text(
          'This permanently deletes everything LocalMind stores on this '
          'device:\n\n'
          '  \u2022  all chat messages\n'
          '  \u2022  memories and notes\n'
          '  \u2022  ingested documents\n'
          '  \u2022  saved cloud API keys\n'
          '  \u2022  all settings\n\n'
          'The app will return to a fresh first-run state.',
          style: TextStyle(fontSize: 13, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (first != true) {
      _confirm.cancel();
      return;
    }
    _confirm.confirmFirst();

    // ---- Step 2: the real second confirmation ---------------------------
    var deleteModels = false;
    final second = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Last chance — this cannot be undone'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Are you sure? Once erased, this data cannot be recovered.',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: deleteModels,
                onChanged: (v) => setLocal(() => deleteModels = v ?? false),
                title: const Text('Also delete downloaded models',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  'Frees disk space. Files under '
                  '"${AppConstants.modelsDirName}/" in this app\'s documents '
                  'folder; they can be downloaded again.',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Erase everything'),
            ),
          ],
        ),
      ),
    );

    // The gate only opens when both steps genuinely happened.
    if (second != true || !_confirm.confirmSecond()) {
      _confirm.cancel();
      return;
    }

    await _runErase(deleteModels);
  }

  Future<void> _runErase(bool deleteModels) async {
    setState(() => _busy = true);
    try {
      // Rows first: messages, memories, notes, documents, activity log and
      // preferences. This is the existing wipe(); it was previously uncalled.
      await DatabaseHelper.instance.wipe();

      // Secrets in the platform keystore: the cloud API keys and the database
      // key that encrypted the (now deleted) rows.
      await SecureStore.instance.wipe();

      // shared_preferences: active model selections and similar.
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();

      // Optionally the downloaded GGUFs, under <app documents>/models/.
      if (deleteModels) {
        try {
          final docs = await getApplicationDocumentsDirectory();
          final models =
              Directory('${docs.path}/${AppConstants.modelsDirName}');
          if (await models.exists()) {
            await models.delete(recursive: true);
          }
          Log.i('erased downloaded models from ${models.path}');
        } catch (e) {
          // Not fatal: the data itself is gone; only disk space was not freed.
          Log.w('could not delete downloaded models: $e');
        }
      }

      // Back to a clean first-run state in memory, then on screen.
      await ref.read(settingsProvider.notifier).resetToDefaults();
      ref.invalidate(chatMessagesProvider);
      ref.invalidate(activityLogProvider);

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (route) => false,
      );
    } catch (e) {
      Log.e('erase all data failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erase failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

extension StringExtension on String {
  String capitalize() {
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}
