/// Settings screen.
///
/// Grouped into named sections rather than a flat run of dividers. A settings
/// list is a map, and the previous layout — twelve tiles separated by rules,
/// with no grouping — made every entry look equally important, including
/// "Erase all data". Section headers say which bucket a control is in and the
/// one-line subtitles say what the bucket does.
///
/// Everything functional is unchanged: the same providers, the same dialogs,
/// the same two-step confirmation on the destructive action. Only the
/// presentation moved.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../core/utils/log.dart';
import '../../data/database/database_helper.dart';
import '../../data/services/secure_store.dart';
import '../../domain/models/cloud_provider.dart';
import '../providers/providers.dart';
import '../widgets/screen_section_card.dart';
import 'cloud_screen.dart';
import 'models_screen.dart';
import 'onboarding_screen.dart';
import 'performance_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final permissions = ref.watch(toolPermissionsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // Model Management — the real chooser/downloader.
          const ScreenSection(
            title: 'Models & inference',
            subtitle:
                'What runs the assistant, and how well it answers. The model '
                'itself is downloaded to this device.',
            padding: EdgeInsets.zero,
            child: ModelsTile(),
          ),

          const SizedBox(height: 20),

          const ScreenSection(
            title: 'Assistant',
            subtitle:
                'How the model is addressed. Context is how much of a '
                'conversation it can hold at once.',
            padding: EdgeInsets.zero,
            child: _AssistantGroup(),
          ),

          const SizedBox(height: 20),

          const ScreenSection(
            title: 'Voice',
            subtitle: 'Speaking and listening.',
            padding: EdgeInsets.zero,
            child: VoiceSettings(),
          ),

          const SizedBox(height: 20),

          ScreenSection(
            title: 'Privacy & security',
            subtitle:
                'What the agent may do on this device, and whether anything '
                'is ever sent off it.',
            padding: EdgeInsets.zero,
            child: PermissionList(permissions: permissions),
          ),

          const SizedBox(height: 20),

          const ScreenSection(
            title: 'Cloud',
            subtitle:
                'Cloud is off until you add a key and confirm. The on-device '
                'model stays the default.',
            padding: EdgeInsets.zero,
            child: CloudPrivacySection(),
          ),

          const SizedBox(height: 20),

          const ScreenSection(
            title: 'Data',
            subtitle: 'Everything this app stores lives here.',
            padding: EdgeInsets.zero,
            child: EraseDataSection(),
          ),

          const SizedBox(height: 20),

          const ScreenSection(
            title: 'About',
            subtitle: 'Diagnostics, cloud models and version.',
            padding: EdgeInsets.zero,
            child: AboutSection(),
          ),
        ],
      ),
    );
  }
}

/// Personality and context size, side by side.
///
/// They belong together: both change how the model answers, and a user tuning
/// "it forgets what I said" wants both within reach.
class _AssistantGroup extends ConsumerWidget {
  const _AssistantGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const ScreenRowIcon(icon: Icons.person_outline, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Personality',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: PersonalitySelector(current: settings['personality'] as String?),
        ),
        const ScreenRowDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const ScreenRowIcon(icon: Icons.tune, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Context size',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ContextSizeSelector(current: settings['context_size'] as int?),
        ),
      ],
    );
  }
}

/// Entry point into the Models chooser/downloader.
class ModelsTile extends ConsumerWidget {
  const ModelsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final llmService = ref.read(llmServiceProvider);
    final loaded = llmService.isLoaded;

    return ListTile(
      leading: const ScreenRowIcon(icon: Icons.model_training),
      title: const Text('Download and select models'),
      subtitle: Text(
        loaded
            ? 'Loaded: ${llmService.modelPath}'
            : 'No model loaded',
      ),
      trailing: Icon(
        loaded ? Icons.check_circle : Icons.warning_amber_rounded,
        color: loaded ? AppColors.success : AppColors.warning,
      ),
      onTap: () => Navigator.of(
        context,
      ).push(AppPageRoute(builder: (_) => const ModelsScreen())),
    );
  }
}

/// Permission list widget
class PermissionList extends ConsumerWidget {
  final Map<String, String> permissions;

  const PermissionList({super.key, required this.permissions});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tools = AppConstants.defaultPermissions.keys.toList();

    return Column(
      children: [
        for (var i = 0; i < tools.length; i++) ...[
          _permissionRow(context, ref, tools[i]),
          if (i != tools.length - 1) const ScreenRowDivider(),
        ],
      ],
    );
  }

  Widget _permissionRow(BuildContext context, WidgetRef ref, String tool) {
    final current = permissions[tool] ?? 'ask';

    // The permission word is the most consequential thing on this row, so it
    // carries the colour: green runs freely, amber asks first, red is refused.
    final tint = switch (current) {
      AppConstants.permissionAllow => AppColors.success,
      AppConstants.permissionBlock => AppColors.danger,
      _ => AppColors.warning,
    };

    return ListTile(
      leading: ScreenRowIcon(icon: _getToolIcon(tool), color: tint, size: 34),
      title: Text(_getToolName(tool)),
      subtitle: Text('Permission: $current'),
      trailing: PopupMenuButton<String>(
        initialValue: current,
        tooltip: 'Permission',
        onSelected: (value) {
          ref
              .read(toolPermissionsProvider.notifier)
              .setPermission(tool, value);
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'allow', child: Text('Allow')),
          const PopupMenuItem(value: 'ask', child: Text('Ask')),
          const PopupMenuItem(value: 'block', child: Text('Block')),
        ],
      ),
    );
  }

  IconData _getToolIcon(String tool) {
    switch (tool) {
      case 'send_sms':
        return Icons.sms_outlined;
      case 'create_calendar_event':
        return Icons.event_outlined;
      case 'add_contact':
        return Icons.person_add_alt_1_outlined;
      case 'set_alarm':
        return Icons.alarm_outlined;
      case 'open_app':
        return Icons.apps_outlined;
      case 'web_search':
        return Icons.search;
      case 'get_location':
        return Icons.location_on_outlined;
      case 'create_note':
        return Icons.note_add_outlined;
      case 'read_notes':
        return Icons.library_books_outlined;
      default:
        return Icons.handyman_outlined;
    }
  }

  String _getToolName(String tool) {
    switch (tool) {
      case 'send_sms':
        return 'Send SMS';
      case 'create_calendar_event':
        return 'Calendar Event';
      case 'add_contact':
        return 'Add Contact';
      case 'set_alarm':
        return 'Set Alarm';
      case 'open_app':
        return 'Open App';
      case 'web_search':
        return 'Web Search';
      case 'get_location':
        return 'Get Location';
      case 'create_note':
        return 'Create Note';
      case 'read_notes':
        return 'Read Notes';
      default:
        return tool;
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
              ref
                  .read(settingsProvider.notifier)
                  .updateSetting('personality', value);
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
      secondary: const ScreenRowIcon(icon: Icons.record_voice_over_outlined),
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
              ref
                  .read(settingsProvider.notifier)
                  .updateSetting('context_size', value);
            }
          },
        );
      }).toList(),
    );
  }
}

/// About section widget
///
/// Stateful only so the installed version is read once per mount: it comes
/// from a platform channel, and rebuilding it on every settings change would
/// put a channel round-trip behind each tap.
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  late final Future<String> _version = AppConstants.resolvedVersion();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NavRow(
          icon: Icons.speed,
          title: 'Performance',
          subtitle: 'Backend, chipset and a throughput benchmark',
          onTap: () => Navigator.of(context).push(
            AppPageRoute(builder: (_) => const PerformanceScreen()),
          ),
        ),
        const ScreenRowDivider(),
        _NavRow(
          icon: Icons.cloud_queue,
          title: 'Cloud Models',
          subtitle: 'Bring your own API key — optional, off by default',
          onTap: () => Navigator.of(context).push(
            AppPageRoute(builder: (_) => const CloudModelsScreen()),
          ),
        ),
        const ScreenRowDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              const ScreenRowIcon(icon: Icons.info_outline),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Version'),
                    const SizedBox(height: 2),
                    // The installed version, read from the package rather than
                    // a compiled-in constant that drifts from the release tag.
                    FutureBuilder<String>(
                      future: _version,
                      builder: (context, snap) => Text(
                        snap.data ?? AppConstants.appVersion,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              const ScreenRowIcon(icon: Icons.public),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('License'),
                    SizedBox(height: 2),
                    Text('MIT License'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.brand, Color(0xFF8B5CF6)],
                      ),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.psychology_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    AppConstants.appName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                // The same words the splash screen shows, so the two never
                // disagree about what the product calls itself.
                'Your private AI agent — fully on device.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A settings row that navigates: leading icon, two lines, chevron.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ScreenRowIcon(icon: icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
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

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScreenRowIcon(
                icon: granted ? Icons.cloud_done : Icons.cloud_off,
                color: granted ? AppColors.success : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Cloud use',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (provider == null)
            Text(
              'No cloud provider is selected, so nothing is ever sent off '
              'this device. To allow cloud use, add a provider under Cloud '
              'Models; you will be asked to confirm exactly what is shared '
              'before the first request.',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else ...[
            Text(
              granted
                  ? 'Cloud is enabled for ${provider.displayName}.'
                  : 'Cloud is off for ${provider.displayName}. Nothing is '
                        'sent until you confirm.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (!granted)
              FilledButton.icon(
                onPressed: () => _confirmConsent(context, ref, provider),
                icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                label: Text('Enable cloud for ${provider.displayName}'),
              )
            else
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(settingsProvider.notifier).revokeCloudConsent();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Cloud consent withdrawn.')),
                  );
                },
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Withdraw consent'),
              ),
          ],
        ],
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
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          ScreenRowIcon(icon: Icons.delete_forever, color: AppColors.danger),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Erase all data',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  'Delete chat history, memories, notes, documents, API keys '
                  'and settings, and return to first run.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    side: BorderSide(
                      color: AppColors.danger.withValues(alpha: 0.5),
                    ),
                  ),
                  onPressed: _busy ? null : _startErase,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline, size: 18),
                  label: Text(_busy ? 'Erasing…' : 'Erase everything'),
                ),
              ],
            ),
          ),
        ],
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
                title: const Text(
                  'Also delete downloaded models',
                  style: TextStyle(fontSize: 13),
                ),
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
          final models = Directory(
            '${docs.path}/${AppConstants.modelsDirName}',
          );
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
        AppPageRoute(builder: (_) => const OnboardingScreen()),
        (route) => false,
      );
    } catch (e) {
      Log.e('erase all data failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erase failed: $e')));
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