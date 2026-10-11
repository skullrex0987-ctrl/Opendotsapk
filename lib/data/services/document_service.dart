/// Document ingestion — turn a picked file into text the agent can use.
///
/// Formats and why:
///  * **Plain text family** (txt, md, csv, json, log, yaml, and code files) is
///    read directly. No dependency, exact fidelity, and it covers most of what
///    people actually want to ask about.
///  * **PDF** goes through the in-process extractor in `pdf_text_extractor.dart`,
///    which inflates FlateDecode content streams before scanning for text.
///    Scanned PDFs have no text layer and yield nothing — that is reported
///    honestly rather than producing an empty "summary" of nothing.
///  * **DOCX** is a ZIP of XML; the whole document body is one `word/`
///    entry, so it is unzipped in-process and stripped of tags. No dependency.
///
/// OCR is deliberately **not** included. Every Android OCR path either pulls in
/// Google Play Services (contradicting the offline promise) or adds a bundled
/// model of tens of megabytes to an APK that already ships three native
/// runtimes. A scanned PDF is reported as such, and the user can paste the text.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/log.dart';
import '../../core/utils/text_utils.dart';
import 'pdf_text_extractor.dart';

class IngestedDocument {
  final String name;
  final String text;
  final String mimeGuess;

  /// Chunks ready to embed, already windowed by [TextUtils.chunk].
  final List<String> chunks;

  /// Set when the file was readable but contained no extractable text, which
  /// is the common case for a scanned PDF.
  final bool textLayerMissing;

  const IngestedDocument({
    required this.name,
    required this.text,
    required this.chunks,
    this.mimeGuess = 'text/plain',
    this.textLayerMissing = false,
  });

  int get charCount => text.length;

  int get estimatedTokens => TextUtils.estimateTokens(text);

  String get preview => TextUtils.ellipsize(text.replaceAll('\n', ' '), 180);
}

class DocumentService {
  DocumentService._();

  static DocumentService? _instance;
  static DocumentService get instance => _instance ??= DocumentService._();

  /// Hard ceiling on file size. A 50 MB text file would produce tens of
  /// thousands of embeddings, which would take longer than the battery allows.
  static const int maxBytes = 8 * 1024 * 1024;

  static const Set<String> _plainExtensions = {
    'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'jsonl', 'log',
    'yaml', 'yml', 'xml', 'html', 'htm', 'ini', 'conf', 'toml',
    'dart', 'py', 'js', 'ts', 'java', 'kt', 'go', 'rs', 'c', 'h',
    'cpp', 'hpp', 'cs', 'rb', 'php', 'swift', 'sh', 'bash', 'sql',
  };

  bool isSupported(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return _plainExtensions.contains(ext) ||
        ext == 'pdf' ||
        ext == 'docx' ||
        ext == 'epub';
  }

  /// Human-readable list for the picker's subtitle.
  static String get supportedSummary =>
      'txt, md, csv, json, yaml, xml, log, code files, PDF, DOCX, EPUB';

  /// Read and chunk a file. Throws [DocumentException] with a readable message.
  Future<IngestedDocument> ingest(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const DocumentException('That file no longer exists.');
    }

    final size = await file.length();
    if (size > maxBytes) {
      throw DocumentException(
        'That file is ${(size / 1048576).toStringAsFixed(1)} MB. '
        'The limit is ${maxBytes ~/ 1048576} MB so embedding stays fast.',
      );
    }

    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');

    late final String text;
    switch (ext) {
      case 'pdf':
        text = await _readPdf(file, name);
      case 'docx':
        text = await _readDocx(file);
      case 'epub':
        text = await _readEpub(file);
      default:
        text = await _readPlain(file);
    }

    final clean = _clean(text);

    if (clean.trim().isEmpty) {
      return IngestedDocument(
        name: name,
        text: '',
        chunks: const [],
        textLayerMissing: ext == 'pdf',
      );
    }

    final chunks = TextUtils.chunk(clean);
    Log.i('ingested "$name": ${clean.length} chars -> ${chunks.length} chunks');

    return IngestedDocument(
      name: name,
      text: clean,
      chunks: chunks,
      mimeGuess: ext == 'pdf' ? 'application/pdf' : 'text/plain',
    );
  }

  // ------------------------------------------------------------- readers

  Future<String> _readPlain(File file) async {
    final bytes = await file.readAsBytes();
    // Honour a BOM so UTF-8/UTF-16 files from Windows editors do not arrive
    // with a stray glyph at the front.
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: true);
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: false);
      }
    }
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  static String _decodeUtf16(Uint8List b, {required bool littleEndian}) {
    final codes = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      codes.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(codes);
  }

  /// Extract a PDF's text layer.
  ///
  /// Uses the in-process extractor in `pdf_text_extractor.dart`, which inflates
  /// FlateDecode content streams. The previous implementation regex-scanned raw
  /// bytes and never inflated, so it found nothing in any PDF that compressed
  /// its content — which is almost all of them.
  ///
  /// Returns an empty string when there is no text layer. That is **not** an
  /// error and must not throw: a scanned PDF is a perfectly normal file. The
  /// caller flags it via `textLayerMissing` so the UI can explain it, and
  /// throwing here would make a scan look like a corrupt document.
  Future<String> _readPdf(File file, String name) async {
    final bytes = await file.readAsBytes();
    final text = extractPdfText(bytes);

    if (text.trim().isEmpty) {
      Log.w('pdf "$name" has no text layer (${bytes.length} bytes)');
    }
    return text;
  }

  /// DOCX is a ZIP; `word/document.xml` holds the body.
  Future<String> _readDocx(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);

    final buf = StringBuffer();
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final n = entry.name;
      if (n != 'word/document.xml' && !n.startsWith('word/footnotes')) continue;

      final xml = utf8.decode(entry.content as List<int>, allowMalformed: true);
      buf.writeln(_xmlToText(xml));
    }

    if (buf.isEmpty) {
      throw const DocumentException('That .docx has no readable body text.');
    }
    return buf.toString();
  }

  /// EPUB is a ZIP of XHTML. Pull every document part and strip tags.
  Future<String> _readEpub(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);

    final buf = StringBuffer();
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final n = entry.name.toLowerCase();
      if (!(n.endsWith('.xhtml') || n.endsWith('.html') || n.endsWith('.htm'))) {
        continue;
      }
      final html = utf8.decode(entry.content as List<int>, allowMalformed: true);
      buf.writeln(_xmlToText(html));
    }

    if (buf.isEmpty) {
      throw const DocumentException('That EPUB had no readable chapters.');
    }
    return buf.toString();
  }

  /// Crude but effective tag stripper: keeps text nodes, inserts breaks at
  /// block-level boundaries so paragraphs do not run together.
  static String _xmlToText(String xml) {
    var s = xml;

    // Drop anything that is not content.
    s = s.replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>',
        caseSensitive: false, dotAll: true), ' ');
    // Paragraph and line breaks become newlines.
    s = s.replaceAll(
      RegExp(r'</(w:p|w:tr|p|div|br|li|h[1-6]|tr|section)>',
          caseSensitive: false),
      '\n',
    );
    s = s.replaceAll(RegExp(r'<w:br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
    // Entities that matter for readability.
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    s = s.replaceAll(RegExp(r'&#x?[0-9a-fA-F]+;'), ' ');
    return s;
  }

  /// Collapse the whitespace soup that extraction produces.
  static String _clean(String s) {
    var out = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // Tabs and runs of spaces.
    out = out.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
    // Three or more newlines -> two.
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    // Lines that are only punctuation are extraction artefacts.
    out = out
        .split('\n')
        .where((l) => !RegExp(r'^[\s\-_=*·•]+$').hasMatch(l))
        .join('\n');
    return out.trim();
  }
}

class DocumentException implements Exception {
  final String message;
  const DocumentException(this.message);

  @override
  String toString() => message;
}

/// PDF text extraction lives in `pdf_text_extractor.dart`.
///
/// The class that used to sit here regex-scanned the raw file for `(...)Tj`
/// without ever inflating FlateDecode content streams, so it returned nothing
/// for essentially every real-world PDF. It also called a `flutter_pdf_text`
/// API the project does not depend on.

