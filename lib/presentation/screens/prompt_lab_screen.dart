/// Prompt Lab — single-turn testing with temperature and top-k controls.
///
/// Inspired by Google AI Edge Gallery's Prompt Lab screen. Lets users run
/// one-off prompts against the loaded model with adjustable parameters,
/// useful for benchmarking and quick experimentation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/motion.dart';
import '../../data/services/model_manager.dart';
import '../../data/services/llm_service.dart';
import '../../providers/providers.dart';

class PromptLabScreen extends ConsumerStatefulWidget {
  const PromptLabScreen({super.key});

  @override
  ConsumerState<PromptLabScreen> createState() => _PromptLabScreenState();
}

class _PromptLabScreenState extends ConsumerState<PromptLabScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  double _temperature = 0.7;
  int _topK = 40;
  int _maxTokens = 512;
  bool _isRunning = false;
  String _result = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppMotion.base,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _promptController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _runPrompt() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _isRunning = true;
      _result = '';
      _error = null;
    });

    try {
      final llmService = ref.read(llmServiceProvider);
      if (!llmService.isLoaded) {
        setState(() {
          _error = 'No model loaded. Download one in Settings > Models.';
          _isRunning = false;
        });
        return;
      }

      final response = await llmService.generate(
        prompt: prompt,
        maxTokens: _maxTokens,
      );
      if (!mounted) return;

      setState(() {
        _result = response;
        _isRunning = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Error: $e';
        _isRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt Lab'),
        backgroundColor: theme.scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: FadeSlideIn(
        delay: Duration.zero,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          children: [
            // Prompt input
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Prompt',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _promptController,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Enter your prompt here...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Parameters
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Parameters',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    _ParamSlider(
                      label: 'Temperature',
                      value: _temperature,
                      min: 0.0,
                      max: 2.0,
                      divisions: 20,
                      onChanged: (v) => setState(() => _temperature = v),
                    ),
                    const SizedBox(height: 12),
                    _ParamSlider(
                      label: 'Top-K',
                      value: _topK.toDouble(),
                      min: 1,
                      max: 100,
                      divisions: 99,
                      onChanged: (v) => setState(() => _topK = v.round()),
                    ),
                    const SizedBox(height: 12),
                    _ParamSlider(
                      label: 'Max Tokens',
                      value: _maxTokens.toDouble(),
                      min: 64,
                      max: 2048,
                      divisions: 32,
                      onChanged: (v) => setState(() => _maxTokens = v.round()),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Run button
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isRunning ? null : _runPrompt,
                icon: _isRunning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(_isRunning ? 'Running...' : 'Run Prompt'),
              ),
            ),
            const SizedBox(height: 24),

            // Result
            if (_result.isNotEmpty || _error != null)
              Card(
                color: _error != null
                    ? scheme.errorContainer.withValues(alpha: 0.1)
                    : scheme.primaryContainer.withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _error != null ? Icons.error_outline : Icons.assistant,
                            color: _error != null
                                ? scheme.error
                                : scheme.primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _error != null ? 'Error' : 'Result',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: _error != null ? scheme.error : scheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        _error ?? _result,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ParamSlider extends StatelessWidget {
  const _ParamSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: theme.textTheme.labelLarge),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
              ),
              child: Text(
                value.toStringAsFixed(value == value.toInt() ? 0 : 2),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: value.toStringAsFixed(value == value.toInt() ? 0 : 2),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
