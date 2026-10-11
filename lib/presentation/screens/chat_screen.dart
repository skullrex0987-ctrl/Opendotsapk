/// Main chat screen
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../providers/providers.dart';
import '../widgets/message_bubble.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/log.dart';
import '../../core/utils/text_utils.dart';
import '../../core/utils/turn_builder.dart';
import '../../data/services/document_service.dart';
import '../../data/services/gpu_service.dart';
import '../../data/services/cloud_service.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/router_service.dart';
import '../../domain/models/models.dart';

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

  /// Local file paths of images queued for the next turn.
  ///
  /// Held as paths rather than bytes: the vision model reads from disk, and
  /// keeping base64 in widget state would balloon memory during a long chat.
  final List<String> _attachedImages = [];

  /// Documents ingested this session, available as RAG context.
  final List<IngestedDocument> _attachedDocs = [];

  /// Set after a send so the UI can show where the turn actually ran.
  String? _lastRoute;

  /// The in-flight cloud request, held so Stop can actually cancel it. The
  /// local path is stopped through `LlmService.stop()` instead.
  StreamSubscription<String>? _cloudSub;

  /// Set when the user asks to stop. The token loop checks it and **keeps the
  /// partial text** rather than throwing away a half-finished reply.
  bool _stopRequested = false;

  /// Tokens waiting to be shown.
  ///
  /// `setState` used to run once per token, rebuilding this entire screen
  /// hundreds of times a second for no visible benefit. Tokens now accumulate
  /// here and are flushed on a timer.
  String _pendingTokens = '';
  Timer? _flushTimer;

  @override
  void dispose() {
    _flushTimer?.cancel();
    _cloudSub?.cancel();
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
              if (value == 'export') _exportChat();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'model',
                child: Text('Select Model'),
              ),
              PopupMenuItem(
                value: 'export',
                child: Text('Export chat'),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_modelStatusIcon(settings), color: Colors.grey[400]),
                const SizedBox(width: 4),
                Text(
                  _modelStatusLabel(settings),
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

          // Attachment previews
          if (_attachedImages.isNotEmpty || _attachedDocs.isNotEmpty)
            _buildAttachmentStrip(),

          // Route badge: say plainly where the last turn ran.
          if (_lastRoute != null) _buildRouteBadge(),

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
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: _pickImage,
                  tooltip: 'Attach an image (needs a vision model)',
                  color: Colors.grey[400],
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickDocument,
                  tooltip: 'Attach a document: ${DocumentService.supportedSummary}',
                  color: Colors.grey[400],
                ),
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
                // While a reply streams this becomes Stop. It used to be merely
                // disabled, so there was no way to cancel one — the only cancel
                // icon in the composer removed an attached image.
                IconButton(
                  icon: Icon(_isThinking ? Icons.stop_circle : Icons.send),
                  tooltip: _isThinking ? 'Stop generating' : 'Send',
                  onPressed: _isThinking
                      ? () => _stopGeneration()
                      : () => _sendMessage(),
                  color: _isThinking
                      ? Theme.of(context).colorScheme.error
                      : AppConstants.primaryColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Badge under the composer showing the router's decision.
  Widget _buildRouteBadge() {
    final isCloud = _lastRoute!.toLowerCase().contains('cloud') ||
        _lastRoute!.toLowerCase().contains('sent to');
    return Container(
      width: double.infinity,
      color: isCloud
          ? Colors.orange.withOpacity(0.15)
          : Colors.green.withOpacity(0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(
            isCloud ? Icons.cloud_outlined : Icons.phone_android,
            size: 14,
            color: isCloud ? Colors.orange[300] : Colors.green[300],
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _lastRoute!,
              style: TextStyle(
                fontSize: 11,
                color: isCloud ? Colors.orange[200] : Colors.green[200],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentStrip() {
    return Container(
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final path in _attachedImages)
            Stack(
              children: [
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[700]!),
                    image: DecorationImage(
                      image: FileImage(File(path)),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  top: -4,
                  child: IconButton(
                    iconSize: 16,
                    icon: const Icon(Icons.cancel, color: Colors.redAccent),
                    onPressed: () =>
                        setState(() => _attachedImages.remove(path)),
                  ),
                ),
              ],
            ),
          for (final doc in _attachedDocs)
            Chip(
              avatar: const Icon(Icons.description, size: 16),
              label: Text(
                '${doc.name} (${doc.chunks.length})',
                style: const TextStyle(fontSize: 11),
              ),
              onDeleted: () => setState(() => _attachedDocs.remove(doc)),
            ),
        ],
      ),
    );
  }

  IconData _modelStatusIcon(Map<String, dynamic> settings) {
    final loaded = settings['model_path'] != null;
    return loaded ? Icons.check_circle : Icons.cloud_download;
  }

  String _modelStatusLabel(Map<String, dynamic> settings) {
    if (settings['model_path'] != null) return 'Loaded';
    if (ref.read(llmServiceProvider).isLoaded) return 'Loaded';
    return 'No Model';
  }

  // -------------------------------------------------------------- attachments

  /// Pick an image and queue it for the next turn.
  ///
  /// Vision is only useful with a compatible model attached, so this warns
  /// instead of silently attaching an image that will be ignored.
  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        // Downscale before the model sees it: a 12 MP photo is slow to decode
        // and buys nothing over 1024 px for Moondream-class models.
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (file == null || !mounted) return;

      final llm = ref.read(llmServiceProvider);
      setState(() => _attachedImages.add(file.path));

      if (!llm.isVisionLoaded) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Image attached. The on-device vision model is not loaded — '
              'this turn will use a cloud model if one is configured.',
            ),
          ),
        );
      }
    } catch (e) {
      Log.w('image pick failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the gallery: $e')),
      );
    }
  }

  /// Pick and ingest a document, then hand it to the memory store.
  Future<void> _pickDocument() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      final path = result.isEmpty ? null : result.first.path;
      if (path == null || !mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        final doc = await DocumentService.instance.ingest(path);

        if (doc.textLayerMissing) {
          if (mounted) Navigator.of(context).pop();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'That PDF has no text layer (it looks like a scan). '
                'OCR is not enabled — paste the text instead.',
              ),
            ),
          );
          return;
        }

        // Store chunks with embeddings when the encoder is available, so the
        // document is retrievable by meaning and not only by keyword.
        final db = ref.read(databaseProvider);
        final embed = EmbeddingService.getInstance();
        final id = _uuid.v4();

        await db.insertDocument(
          id: id,
          name: doc.name,
          path: path,
          mime: doc.mimeGuess,
          charCount: doc.charCount,
          chunkCount: doc.chunks.length,
        );

        if (embed.isLoaded && doc.chunks.isNotEmpty) {
          final vectors = <List<double>>[];
          for (final chunk in doc.chunks) {
            vectors.add(await embed.generateEmbedding(chunk));
          }
          await db.insertChunks(
            documentId: id,
            texts: doc.chunks,
            vectors: vectors,
          );
        }

        if (mounted) Navigator.of(context).pop();
        if (!mounted) return;

        setState(() => _attachedDocs.add(doc));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added "${doc.name}" — ${doc.chunks.length} chunk(s), '
              '${doc.estimatedTokens} tokens.',
            ),
          ),
        );
      } catch (e) {
        if (mounted) Navigator.of(context).pop();
        rethrow;
      }
    } catch (e) {
      Log.w('document ingest failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  // ------------------------------------------------------------------- send

  Future<void> _sendMessage([String? text]) async {
    final messageText = text ?? _controller.text.trim();
    final hasImages = _attachedImages.isNotEmpty;
    if (messageText.isEmpty && !hasImages && _attachedDocs.isEmpty) return;

    _controller.clear();

    // Snapshot attachments, then clear so the next turn starts fresh.
    final imagePath = hasImages ? _attachedImages.first : null;
    final docCtx = _attachedDocs.isEmpty
        ? ''
        : '\n\nContext from attached documents:\n'
            '${_attachedDocs.map((d) => '--- ${d.name} ---\n${TextUtils.ellipsize(d.text, 4000)}').join('\n\n')}';

    final display = messageText.isEmpty
        ? (hasImages ? '(image)' : '(document)')
        : messageText;

    setState(() {
      _attachedImages.clear();
      _attachedDocs.clear();
    });

    // Snapshot the conversation BEFORE this message is appended. The old code
    // read it afterwards and then appended the message again, so the model was
    // given the question twice.
    final priorHistory = List<ChatMessage>.from(ref.read(chatMessagesProvider));

    _stopRequested = false;
    _pendingTokens = '';

    // Add user message
    final userMessage = ChatMessage(
      id: _uuid.v4(),
      role: 'user',
      content: imagePath != null ? '$display\n[image attached]' : display,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(chatMessagesProvider.notifier).addMessage(userMessage);

    // ---- route this turn ------------------------------------------------
    final llmService = ref.read(llmServiceProvider);
    final settings = ref.read(settingsProvider);
    final router = RouterService.instance;
    final decision = router.decide(
      prompt: '$display$docCtx',
      config: RoutingConfig(
        mode: '${settings['cloud_mode'] ?? 'auto'}',
        privateMode: settings['private_mode'] as bool? ?? false,
        preferLocalOnMetered:
            settings['prefer_local_metered'] as bool? ?? true,
      ),
      hasImages: hasImages,
      localVisionReady: llmService.isVisionLoaded,
      localModelReady: llmService.isLoaded,
    );

    if (context.mounted) setState(() => _lastRoute = decision.reason);

    if (decision.isCloud) {
      await _sendViaCloud(decision, '$display$docCtx', imagePath, priorHistory);
      return;
    }

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
      final request = _buildRequest(
        message: '$display$docCtx',
        priorHistory: priorHistory,
      );

      // Streaming response
      await for (final token in llmService.generateStream(
        prompt: request.prompt,
        systemPrompt: request.systemPrompt,
        history: request.history,
        maxTokens: _maxResponseTokens,
        imagePath: imagePath,
      )) {
        if (_stopRequested) break;
        _bufferToken(token);
      }

      _flushNow();
      await _finishAssistantMessage();
    } catch (e) {
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

  /// Send the turn to the selected cloud provider instead of the local model.
  Future<void> _sendViaCloud(
    RouteDecision decision,
    String prompt,
    String? imagePath,
    List<ChatMessage> priorHistory,
  ) async {
    final provider = decision.provider;
    if (provider == null) {
      await _showModelNotLoadedDialog();
      return;
    }

    setState(() {
      _isThinking = true;
      _currentResponse = '';
    });

    try {
      // Same newest-first, budgeted selection as the local path. This used to
      // be `history.take(12)`, i.e. the twelve OLDEST messages.
      final request = _buildRequest(
        message: prompt,
        priorHistory: priorHistory,
      );
      final messages = <Map<String, String>>[
        if (request.systemPrompt != null)
          {'role': 'system', 'content': request.systemPrompt!},
        ...request.history,
        {'role': 'user', 'content': request.prompt},
      ];

      final imagesB64 = <String>[];
      if (imagePath != null) {
        try {
          imagesB64.add(base64Encode(await File(imagePath).readAsBytes()));
        } catch (e) {
          Log.w('could not read image for cloud: $e');
        }
      }

      final cloud = ref.read(cloudServiceProvider);

      // Listen through a subscription rather than `await for` so Stop has
      // something it can actually cancel.
      final completer = Completer<void>();
      _cloudSub = cloud
          .stream(
            provider: provider,
            turn: CloudTurn(
              modelId: decision.modelId,
              messages: messages,
              imageBase64: imagesB64,
            ),
          )
          .listen(
            (token) {
              if (_stopRequested) return;
              _bufferToken(token);
            },
            onError: (Object e) {
              if (!completer.isCompleted) completer.completeError(e);
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            cancelOnError: true,
          );

      try {
        await completer.future;
      } finally {
        await _cloudSub?.cancel();
        _cloudSub = null;
      }

      _flushNow();
      await _finishAssistantMessage();
    } catch (e) {
      Log.w('cloud turn failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
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

  /// Persist the assistant reply, then speak it if TTS is on.
  Future<void> _finishAssistantMessage() async {
    if (_currentResponse.trim().isEmpty) return;

    // A stopped reply is kept and labelled rather than discarded: half a useful
    // answer is worth more than none, but the history should say what happened.
    final content = _stopRequested
        ? '$_currentResponse\n\n_(stopped)_'
        : _currentResponse;

    final assistantMessage = ChatMessage(
      id: _uuid.v4(),
      role: 'assistant',
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await ref.read(chatMessagesProvider.notifier).addMessage(assistantMessage);

    // Speaking a half-finished sentence is worse than not speaking it.
    if (_stopRequested) return;

    final ttsEnabled =
        ref.read(settingsProvider)['tts_enabled'] as bool? ?? true;
    if (ttsEnabled) {
      await ref.read(textToSpeechProvider.notifier).speak(_currentResponse);
    }
  }

  Future<void> _exportChat() async {
    final messages = ref.read(chatMessagesProvider);
    if (messages.isEmpty) return;

    final buf = StringBuffer('# LocalMind chat export\n\n');
    for (final m in messages) {
      buf.writeln('**${m.role}** (${m.timestamp})');
      buf.writeln(m.content);
      buf.writeln();
    }

    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/localmind-chat.md');
      await file.writeAsString(buf.toString());
      await Share.shareXFiles([XFile(file.path)], text: 'LocalMind chat');
    } catch (e) {
      Log.w('export failed: $e');
    }
  }
  
  /// Tokens reserved for the reply when budgeting history.
  ///
  /// Without this the transcript can fill the whole context window and the
  /// model has no room left to answer.
  static const int _maxResponseTokens = 512;

  /// Builds the system prompt, the question, and the history to send.
  ///
  /// [priorHistory] must be the conversation **before** the current message.
  /// The old code read the provider *after* appending the user message and then
  /// appended it to the prompt again, so the model saw the question twice.
  ///
  /// Selection is newest-first under a token budget (see [buildRecentTurns]).
  /// The old `history.take(10)` took the ten OLDEST messages of a chronological
  /// list, so a long conversation sent the opening turns and nothing recent.
  ///
  /// The return is split into the parts `LlmService.generateStream` expects,
  /// which is what keeps `test/llm_wire_format_test.dart` green.
  ({String prompt, String? systemPrompt, List<Map<String, String>> history})
      _buildRequest({
    required String message,
    required List<ChatMessage> priorHistory,
  }) {
    final settings = ref.read(settingsProvider);
    final personality = settings['personality'] as String?;
    final nCtx = ref.read(llmServiceProvider).contextSize;

    final selection = buildRecentTurns(
      history: [
        for (final m in priorHistory) Turn(m.role, m.content),
        Turn('user', message),
      ],
      tokenBudget: nCtx,
      systemPrompt: (personality == null || personality.trim().isEmpty)
          ? null
          : personality,
      reserveForResponse: _maxResponseTokens,
    );

    final turns = selection.turns;
    if (turns.isEmpty) {
      return (prompt: message, systemPrompt: null, history: const []);
    }

    final hasSystem = turns.first.role == 'system';
    final systemPrompt = hasSystem ? turns.first.content : null;
    final prompt = turns.last.content;

    // Everything between the system prompt and the question is history.
    final body = turns.sublist(
      hasSystem ? 1 : 0,
      turns.length - 1,
    );

    return (
      prompt: prompt,
      systemPrompt: systemPrompt,
      history: [
        for (final t in body) {'role': t.role, 'content': t.content},
      ],
    );
  }

  /// Buffers a streamed token and schedules one UI update.
  ///
  /// `setState` used to run per token, rebuilding this whole screen hundreds of
  /// times a second for no visible benefit.
  void _bufferToken(String token) {
    _pendingTokens += token;
    _flushTimer ??= Timer(const Duration(milliseconds: 50), _flushNow);
  }

  void _flushNow() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pendingTokens.isEmpty || !mounted) return;
    final chunk = _pendingTokens;
    _pendingTokens = '';
    setState(() => _currentResponse += chunk);
    _scrollToBottom();
  }

  /// Stops generation, keeping whatever text already arrived.
  ///
  /// There was no way to stop a reply at all before this: the only cancel icon
  /// in the composer removed an attached image.
  Future<void> _stopGeneration() async {
    if (!_isThinking || _stopRequested) return;
    _stopRequested = true;

    // The cloud path is cancelled through its subscription; the local path
    // through the service, which closes the stream the loop is awaiting.
    await _cloudSub?.cancel();
    _cloudSub = null;
    try {
      await ref.read(llmServiceProvider).stop();
    } catch (e) {
      Log.w('stop failed: $e');
    }
    _flushNow();
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
            title: const Text('Load Selected Model'),
            subtitle: const Text('Qwen2.5-1.5B-Instruct Q4_K_M'),
            onTap: () => _loadSelectedModels(context, ref),
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
  
  /// Load the models the user selected in Settings -> Models.
  ///
  /// Downloading lives in the Models screen; this binds what is already on disk
  /// into the native runtime: the chat GGUF first, then the vision projector if
  /// one is selected, then the ONNX encoder behind Memory search.
  Future<void> _loadSelectedModels(BuildContext context, WidgetRef ref) async {
    final manager = ModelManager.getInstance();
    final llmService = ref.read(llmServiceProvider);

    final chat = await manager.activeLlm();
    if (!await manager.isInstalled(chat)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No chat model downloaded yet. '
              'Open Settings -> Models and pick one.',
            ),
          ),
        );
      }
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    var ok = false;
    var message = 'Failed to load model';

    try {
      final layers = await GpuService.layersForMode(
        '${ref.read(settingsProvider)['gpu_offload'] ?? 'auto'}',
      );
      ok = await llmService.loadModel(
        await manager.weightPath(chat),
        gpuLayers: layers,
      );

      // Vision is optional — a missing projector must not fail the chat model.
      final vision = await manager.activeVision();
      if (ok && vision != null) {
        final projector = await manager.projectorPath(vision);
        if (projector != null) {
          final visionOk = await llmService.loadVision(projector);
          if (!visionOk) {
            message = '${chat.displayName} loaded, but vision failed to attach.';
          }
        }
      }

      // Embeddings power Memory search; silent failure is fine, the app
      // simply stores memories without retrieving them.
      final embed = await manager.activeEmbedding();
      if (embed != null) {
        final embedService = EmbeddingService.getInstance();
        if (!embedService.isLoaded) {
          await embedService.loadModel(await manager.weightPath(embed));
        }
      }

      if (context.mounted) {
        await ref
            .read(settingsProvider.notifier)
            .updateSetting('model_path', await manager.weightPath(chat));
      }
      if (ok && message == 'Failed to load model') {
        message = '${chat.displayName} ready.';
      }
    } catch (e) {
      ok = false;
      message = 'Error: $e';
    }

    if (context.mounted) Navigator.of(context).pop(); // progress dialog
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _loadModelFromStorage(BuildContext context, WidgetRef ref) async {
    // Pick any GGUF from the device and bind it directly — useful for models
    // the catalog does not know about.
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      final path = result.isEmpty ? null : result.first.path;
      if (path == null || !context.mounted) return;

      if (!path.toLowerCase().endsWith('.gguf')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That is not a .gguf file. Vision projectors must '
                'also be GGUF (mmproj-*.gguf).'),
          ),
        );
        return;
      }

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      final ok = await ref.read(llmServiceProvider).loadModel(
            path,
            gpuLayers: (await GpuService.detect()).recommendedGpuLayers,
          );
      if (context.mounted) Navigator.of(context).pop();
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok ? 'Loaded ${path.split('/').last}' : 'Failed to load that GGUF',
          ),
        ),
      );
    } catch (e) {
      Log.w('load from storage failed: $e');
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not load that file: $e')),
      );
    }
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
