/// Settings screen
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/providers.dart';
import '../../core/constants/app_constants.dart';
import 'chat_screen.dart' show ModelSelectorDialog;

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
          // Model Management
          const SectionTitle(title: 'Model'),
          const ModelSettings(),
          
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

/// Model settings widget
class ModelSettings extends ConsumerWidget {
  const ModelSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final llmService = ref.read(llmServiceProvider);
    
    return ListTile(
      leading: const Icon(Icons.model_training),
      title: const Text('Model'),
      subtitle: Text(
        settings['model_path'] != null 
            ? 'Loaded: ${settings['model_path']}'
            : 'No model loaded',
      ),
      trailing: llmService.isLoaded
          ? const Icon(Icons.check_circle, color: Colors.green)
          : const Icon(Icons.warning, color: Colors.orange),
      onTap: () => _showModelDialog(context, ref),
    );
  }
  
  void _showModelDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => ModelSelectorDialog(),
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

extension StringExtension on String {
  String capitalize() {
    return '${this[0].toUpperCase()}${substring(1)}';
  }
}
