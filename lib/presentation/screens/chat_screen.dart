/// Main chat screen
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../providers/providers.dart';
import '../widgets/message_bubble.dart';
import '../../core/constants/app_constants.dart';
import '../../data/services/model_manager.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final Uuid _uuid = const Uuid();
  bool _isThinking = false;
  String _currentResponse = '';
  
  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(chatMessagesProvider);
    final settings = ref.watch(settingsProvider);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalMind'),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: _clearChat,
            tooltip: 'Clear Chat',
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'model') _showModelSelector();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'model',
                child: Text('Select Model'),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_download, color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text(
                  settings['model_path'] != null ? 'Loaded' : 'No Model',
                  style: TextStyle(color: Colors.grey[400]),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: messages.length + (_isThinking ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == messages.length && _isThinking) {
                  return const ThinkingBubble();
                }
                final message = messages[messages.length - 1 - index];
                return MessageBubble(message: message);
              },
            ),
          ),
          
          // Input area
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.mic),
                  onPressed: _startVoiceInput,
                  color: Colors.grey[400],
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                    maxLines: 4,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _sendMessage,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _isThinking ? null : _sendMessage,
                  color: AppConstants.primaryColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _sendMessage([String? text]) async {
    final messageText = text ?? _controller.text.trim();
    if (messageText.isEmpty) return;
    
    _controller.clear();
    
    // Add user message
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: messageText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(chatMessagesProvider.notifier).addMessage(userMessage);
    
    // Get related memories
    final llmService = ref.read(llmServiceProvider);
    if (!llmService.isLoaded) {
      await _showModelNotLoadedDialog();
      return;
    }
    
    // Process through agent pipeline
    setState(() {
      _isThinking = true;
      _currentResponse = '';
    });
    
    try {
      final orchestrator = ref.read(agentOrchestratorProvider);
      final recentMessages = ref.read(chatMessagesProvider);
      
      // Get streaming response
      await for (final token in llmService.generateStream(
        prompt: _buildPrompt(messageText, recentMessages),
      )) {
        setState(() {
          _currentResponse += token;
        });
      }
      
      // Add assistant message
      final assistantMessage = ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        content: _currentResponse,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      await ref.read(chatMessagesProvider.notifier).addMessage(assistantMessage);
      
      // Enable TTS if configured
      final ttsEnabled = ref.read(settingsProvider)['tts_enabled'] as bool? ?? true;
      if (ttsEnabled) {
        await ref.read(textToSpeechProvider.notifier).speak(_currentResponse);
      }
    } catch (e) {
      // Show error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isThinking = false;
          _currentResponse = '';
        });
        _scrollToBottom();
      }
    }
  }
  
  String _buildPrompt(String message, List<ChatMessage> history) {
    final recentHistory = history.take(10).map((m) {
      return '${m.role}: ${m.content}';
    }).join('\n');
    
    return '''$recentHistory

User: $message

Assistant:
''';
  }
  
  void _clearChat() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Chat'),
        content: const Text('Are you sure you want to clear all messages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref.read(chatMessagesProvider.notifier).clearChat();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
  
  void _showModelSelector() {
    showDialog(
      context: context,
      builder: (context) => const ModelSelectorDialog(),
    );
  }
  
  Future<void> _showModelNotLoadedDialog() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model Not Loaded'),
        content: const Text('Please download and load a model first. Go to Settings > Model Management.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
  
  void _startVoiceInput() async {
    final speechNotifier = ref.read(speechToTextProvider.notifier);
    final isAvailable = ref.read(speechToTextProvider);
    
    if (!isAvailable) {
      await speechNotifier.init();
      if (!ref.read(speechToTextProvider)) return;
    }
    
    final speech = ref.read(speechToTextProvider.notifier);
    final result = await speech.listenOnce();
    
    if (result != null && result.isNotEmpty && mounted) {
      _sendMessage(result);
    }
  }
  
  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }
}

/// Model selector dialog
class ModelSelectorDialog extends ConsumerWidget {
  const ModelSelectorDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    
    return AlertDialog(
      title: const Text('Model Management'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Download Default Model'),
            subtitle: const Text('Qwen2.5-1.5B-Instruct Q4_K_M'),
            onTap: () => _downloadModel(context, ref),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Load from Storage'),
            subtitle: const Text('Select a GGUF file'),
            onTap: () => _loadModelFromStorage(context, ref),
          ),
          if (settings['model_path'] != null) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.check_circle),
              title: Text('Current: ${settings['model_path']}'),
              subtitle: const Text('Model is loaded'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
  
  /// Bind the model the user selected in Settings -> Models.
  ///
  /// Downloading is handled by the Models screen; this only loads an already
  /// downloaded GGUF into the native runtime.
  Future<void> _downloadModel(BuildContext context, WidgetRef ref) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final manager = ModelManager.getInstance();
      final active = await manager.activeLlm();

      if (!await manager.isInstalled(active)) {
        if (context.mounted) Navigator.pop(context);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${active.displayName} is not downloaded yet. '
                'Open Settings -> Models to download it.',
              ),
            ),
          );
        }
        return;
      }

      final modelPath = await manager.weightPath(active);
      final llmService = ref.read(llmServiceProvider);
      final success = await llmService.loadModel(modelPath);
      
      Navigator.pop(context); // Close progress
      
      if (success) {
        await ref.read(settingsProvider.notifier).updateSetting('model_path', modelPath);
        if (context.mounted) {
          Navigator.pop(context); // Close dialog
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Model loaded successfully!')),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to load model')),
          );
        }
      }
    } catch (e) {
      Navigator.pop(context);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
  
  Future<void> _loadModelFromStorage(BuildContext context, WidgetRef ref) async {
    // In production, use file picker
    // For now, show placeholder
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File picker not implemented in demo')),
    );
  }
}

/// Thinking indicator widget
class ThinkingBubble extends StatelessWidget {
  const ThinkingBubble({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              'Thinking...',
              style: TextStyle(color: Colors.grey[400]),
            ),
          ],
        ),
      ),
    );
  }
}
