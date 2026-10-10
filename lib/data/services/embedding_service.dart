/// Embedding service using ONNX Runtime
import 'package:onnxruntime/onnxruntime.dart';
import 'package:onnxruntime_flutter/onnxruntime_flutter.dart';
import 'dart:typed_data';

class EmbeddingService {
  static EmbeddingService? _instance;
  OrtSession? _session;
  bool _isLoaded = false;
  
  EmbeddingService._();
  
  static EmbeddingService getInstance() {
    _instance ??= EmbeddingService._();
    return _instance!;
  }
  
  /// Load embedding model
  Future<bool> loadModel(String modelPath) async {
    try {
      // Load ONNX model from assets or file
      _session = await OrtSession.fromFile(modelPath);
      _isLoaded = true;
      return true;
    } catch (e) {
      print('Failed to load embedding model: $e');
      _isLoaded = false;
      return false;
    }
  }
  
  /// Generate embeddings for text
  Future<List<List<double>>> generateEmbeddings(List<String> texts) async {
    if (!_isLoaded || _session == null) {
      throw Exception('Embedding model not loaded');
    }
    
    final embeddings = <List<double>>[];
    
    for (final text in texts) {
      // Tokenize and encode
      final encoded = await _encode(text);
      
      // Run inference
      final inputTensor = OrtValue.tensorProvider.createTensor(
        encoded.buffer.asUint8List(),
        [1, encoded.length],
      );
      
      final outputs = await _session!.run([
        OrtEntry('input_ids', inputTensor),
      ]);
      
      // Get output embedding
      final outputTensor = outputs[0] as OrtTensor;
      final embedding = outputTensor.data as List<double>;
      
      embeddings.add(embedding);
      
      // Clean up
      inputTensor.dispose();
    }
    
    return embeddings;
  }
  
  /// Generate embedding for single text
  Future<List<double>> generateEmbedding(String text) async {
    final results = await generateEmbeddings([text]);
    return results.first;
  }
  
  /// Encode text for model input
  Future<Int32List> _encode(String text) async {
    // Simple tokenization - in production, use proper BPE tokenizer
    final words = text.split(' ');
    final tokens = Int32List(words.length);
    
    for (int i = 0; i < words.length; i++) {
      // Simple hash-based tokenization
      tokens[i] = words[i].hashCode.remainder(10000).toInt();
    }
    
    return tokens;
  }
  
  /// Check if model is loaded
  bool get isLoaded => _isLoaded;
}
