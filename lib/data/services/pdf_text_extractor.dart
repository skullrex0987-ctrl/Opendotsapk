/// PDF text-layer extraction and archive container limits.
///
/// This is the dependency-light replacement for `flutter_pdf_text` (which was
/// never actually a dependency of this project — see `document_service.dart`).
/// It walks a PDF's content streams directly for the text-showing operators
/// `Tj` / `TJ` / `'` / `"`, inflating `FlateDecode` streams with the `archive`
/// package, which the app already depends on for DOCX/EPUB.
///
/// ## What it does and does not do
///
/// It extracts the text layer that normal office software embeds. A scanned or
/// image-only PDF has no such layer, so [extractPdfText] returns an empty
/// string and the caller reports "no extractable text" honestly instead of
/// inventing a summary. It never throws: malformed input, truncated streams and
/// binary noise all yield `''` or the text recovered up to that point.
///
/// The whole file is scanned byte-by-byte rather than decoded up front, so an
/// embedded FlateDecode blob whose bytes happen to look like `(text) Tj` is not
/// mistaken for operators — only genuinely uncompressed operator text is read
/// that way, and compressed streams are inflated first.
///
/// ## Container guardrails
///
/// DOCX/EPUB/PDF are all attacker-supplied files. [openArchive] caps entry
/// count, per-entry expanded size, total expanded size and expansion ratio, so
/// a decompression bomb is refused with a [LimitException] instead of
/// exhausting memory. Malformed archives are refused the same way rather than
/// crashing the caller.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

// --------------------------------------------------------------------- limits

/// Hard ceiling on how much a single FlateDecode stream may expand to. A PDF
/// object is normally far smaller; this bounds a hostile stream.
const int maxInflatedBytes = 16 * 1024 * 1024;

/// Stop after this many content streams. Prevents a pathological PDF (or a
/// stream that never terminates) from pinning a core indefinitely.
const int maxStreams = 4096;

/// Largest compressed container we will even attempt to open. The document
/// service enforces a smaller file-size cap before we get here; this is the
/// defence-in-depth value for [openArchive] used directly.
const int maxArchiveCompressedBytes = 32 * 1024 * 1024;

/// Largest number of entries allowed in a container.
const int maxArchiveEntries = 2000;

/// Largest total expanded size across all entries.
const int maxArchiveExpanded = 64 * 1024 * 1024;

/// Largest single expanded entry.
const int maxArchiveEntryBytes = 32 * 1024 * 1024;

/// Largest allowed expansion ratio (total expanded / compressed). A genuine
/// document rarely exceeds ~20x; 200x is generous before it looks like a bomb.
const int maxArchiveRatio = 200;

/// Thrown by [openArchive] when a container is malformed or exceeds a limit.
///
/// Carries a human-readable [message]; callers turn it into a user-facing
/// [DocumentException] rather than surfacing the raw text.
class LimitException implements Exception {
  final String message;
  LimitException(this.message);

  @override
  String toString() => message;
}

// ------------------------------------------------------------------ public API

/// Extract the text layer from PDF [bytes].
///
/// Returns `''` when there is no text layer (a scan), when the input is not a
/// PDF, when it is truncated, or when it is otherwise unreadable. This never
/// throws — a malformed file is a normal outcome, not an error.
String extractPdfText(Uint8List bytes) {
  final buf = StringBuffer();
  final n = bytes.length;
  var streams = 0;
  var i = 0;

  // Scan for the `stream` keyword byte-by-byte. Working on bytes (not a decoded
  // string) is what makes this binary-safe: Latin-1 decoding of a compressed
  // blob could otherwise place fake `(…) Tj` text in the buffer.
  while (i + 6 <= n && streams < maxStreams) {
    if (!(bytes[i] == 0x73 && // s
        bytes[i + 1] == 0x74 && // t
        bytes[i + 2] == 0x72 && // r
        bytes[i + 3] == 0x65 && // e
        bytes[i + 4] == 0x61 && // a
        bytes[i + 5] == 0x6D)) {
      // m
      i++;
      continue;
    }
    // `stream` must be a keyword: preceded by a non-letter and followed by EOL.
    if (i > 0) {
      final pb = bytes[i - 1];
      final isLetter = (pb >= 0x41 && pb <= 0x5A) || (pb >= 0x61 && pb <= 0x7A);
      if (isLetter) {
        i += 6;
        continue;
      }
    }
    final b6 = i + 6 < n ? bytes[i + 6] : -1;
    if (b6 != 0x0D && b6 != 0x0A) {
      i += 6;
      continue;
    }

    // Skip the EOL that terminates the `stream` keyword.
    var ds = i + 6;
    if (ds < n && bytes[ds] == 0x0D) ds++;
    if (ds < n && bytes[ds] == 0x0A) ds++;

    final dictWindow = _dictWindow(bytes, i);
    final declared = _directLength(dictWindow);
    final flate = dictWindow.contains('FlateDecode');

    int dataEnd;
    if (declared != null && ds + declared <= n) {
      dataEnd = ds + declared;
    } else {
      // Fall back to scanning for `endstream`.
      final idx = _indexOfAscii(bytes, 'endstream', ds);
      dataEnd = idx < 0 ? n : idx;
      while (dataEnd > ds &&
          (bytes[dataEnd - 1] == 0x0A || bytes[dataEnd - 1] == 0x0D)) {
        dataEnd--;
      }
    }
    if (dataEnd < ds) dataEnd = ds;

    final raw = Uint8List.sublistView(bytes, ds, dataEnd);
    String content;
    if (flate) {
      // Try zlib (RFC 1950) first, then the headerless raw-deflate form some
      // producers write despite declaring FlateDecode.
      var inflated = _inflate(raw, raw: false);
      if (inflated.isEmpty) inflated = _inflate(raw, raw: true);
      if (inflated.isEmpty) {
        // Undecodable stream: skip it rather than giving up on the file.
        i = dataEnd;
        streams++;
        continue;
      }
      content = latin1.decode(inflated, allowInvalid: true);
    } else {
      content = latin1.decode(raw, allowInvalid: true);
    }

    final text = _extractOperators(content);
    if (text.isNotEmpty) {
      buf.write(text);
      buf.write('\n');
    }
    streams++;
    i = dataEnd;
  }

  return buf
      .toString()
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Open a ZIP container (DOCX/EPUB) with limits applied.
///
/// Throws [LimitException] — never a raw decoder error — when the archive is
/// malformed, has too many entries, or would expand past any of the size or
/// ratio caps.
Archive openArchive(Uint8List bytes) {
  if (bytes.length > maxArchiveCompressedBytes) {
    throw LimitException('compressed archive too large: ${bytes.length}');
  }

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: false);
  } catch (e) {
    throw LimitException('archive could not be read: $e');
  }

  if (archive.files.length > maxArchiveEntries) {
    throw LimitException('too many entries: ${archive.files.length}');
  }

  var total = 0;
  for (final e in archive.files) {
    if (e.size > maxArchiveEntryBytes) {
      throw LimitException('entry too large: ${e.name} ${e.size}');
    }
    total += e.size;
    if (total > maxArchiveExpanded) throw LimitException('expanded too large');
  }

  if (bytes.isNotEmpty && total ~/ bytes.length > maxArchiveRatio) {
    throw LimitException('compression ratio too high');
  }

  return archive;
}

/// Thin object wrapper around [extractPdfText] for callers that prefer an
/// instance-style API (the document service did, historically).
class PdfTextExtractor {
  const PdfTextExtractor();

  /// See [extractPdfText]. Returns `''` when there is no text layer.
  String extract(Uint8List bytes) => extractPdfText(bytes);
}

// --------------------------------------------------------------- PDF internals

/// The bytes before a `stream` keyword that may hold its dictionary. Look back
/// a bounded window and start at the last `<<` so `/Filter` and `/Length` are
/// seen even with other entries in between.
String _dictWindow(Uint8List bytes, int streamStart) {
  final from = math.max(0, streamStart - 2048);
  final window = latin1.decode(
    bytes.sublist(from, streamStart),
    allowInvalid: true,
  );
  final openIdx = window.lastIndexOf('<<');
  return openIdx >= 0 ? window.substring(openIdx) : window;
}

/// A direct (not indirect) `/Length` value, or null when absent or indirect.
///
/// `/Length 123` is usable; `/Length 12 0 R` is an indirect reference we do not
/// resolve, so we fall back to scanning for `endstream`.
int? _directLength(String dict) {
  final m = RegExp(r'/Length\s+(\d+)(\s+(\d+)\s+R)?').firstMatch(dict);
  if (m == null) return null;
  if (m.group(2) != null) return null;
  final len = int.tryParse(m.group(1)!);
  if (len == null || len < 0) return null;
  return len;
}

int _indexOfAscii(Uint8List bytes, String needle, int from) {
  final pat = ascii.encode(needle);
  outer:
  for (var i = from; i + pat.length <= bytes.length; i++) {
    for (var j = 0; j < pat.length; j++) {
      if (bytes[i + j] != pat[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Inflate [data], capped at [maxInflatedBytes]. Returns the bytes decoded so
/// far on a decode error rather than throwing, so a partially-valid stream
/// still contributes its leading text.
List<int> _inflate(Uint8List data, {required bool raw}) {
  final out = BytesBuilder(copy: false);
  try {
    final decoded = ZLibDecoder().decodeLazy(InputMemoryStream(data), raw: raw);
    var count = 0;
    while (count < maxInflatedBytes && !decoded.isEOS) {
      out.addByte(decoded.readByte());
      count++;
    }
  } catch (_) {
    return out.takeBytes();
  }
  return out.takeBytes();
}

/// Pull the text operands out of a content stream.
///
/// `Tj`/`TJ` show text; `'`/`"` show text on a new line. Operands accumulate in
/// [pending] until one of those operators is hit, at which point they are
/// emitted; any other operator (a positioning operator, say) discards the
/// pending operands so numbers and names never leak into the output.
String _extractOperators(String s) {
  final buf = StringBuffer();
  final pending = <String>[];
  final n = s.length;
  var i = 0;

  void flush({bool newline = false}) {
    if (pending.isEmpty) return;
    buf.write(pending.join());
    buf.write(newline ? '\n' : ' ');
    pending.clear();
  }

  while (i < n) {
    final c = s.codeUnitAt(i);
    if (c == 0x28) {
      // '(' — a literal string.
      final r = _readLiteral(s, i);
      pending.add(r.$1);
      i = r.$2;
      continue;
    }
    if (c == 0x3C) {
      // '<' — either a hex string or the '<<' dictionary opener.
      if (i + 1 < n && s.codeUnitAt(i + 1) == 0x3C) {
        i += 2;
        continue;
      }
      final r = _readHex(s, i);
      if (r.$1 != null) pending.add(r.$1!);
      i = r.$2;
      continue;
    }
    if (c == 0x5B) {
      // '[' — a TJ array of strings and kerning numbers.
      i++;
      while (i < n && s.codeUnitAt(i) != 0x5D) {
        final ch = s.codeUnitAt(i);
        if (ch == 0x28) {
          final r = _readLiteral(s, i);
          pending.add(r.$1);
          i = r.$2;
        } else if (ch == 0x3C) {
          if (i + 1 < n && s.codeUnitAt(i + 1) == 0x3C) {
            i += 2;
            continue;
          }
          final r = _readHex(s, i);
          if (r.$1 != null) pending.add(r.$1!);
          i = r.$2;
        } else {
          i++;
        }
      }
      if (i < n) i++;
      continue;
    }
    if (_isRegular(c)) {
      final start = i;
      while (i < n && _isRegular(s.codeUnitAt(i))) {
        i++;
      }
      final op = s.substring(start, i);
      if (op == 'Tj' || op == 'TJ') {
        flush();
      } else if (op == "'" || op == '"') {
        flush(newline: true);
      } else {
        pending.clear();
      }
      continue;
    }
    i++;
  }
  return buf.toString().trim();
}

bool _isRegular(int c) =>
    c > 0x20 &&
    c < 0x7F &&
    c != 0x28 && // (
    c != 0x29 && // )
    c != 0x3C && // <
    c != 0x3E && // >
    c != 0x5B && // [
    c != 0x5D && // ]
    c != 0x7B && // {
    c != 0x7D && // }
    c != 0x2F && // /
    c != 0x25; // %

/// Read a `(literal)` string starting at [start] (the `(`), honouring escapes
/// and balanced parentheses. Returns the string and the index just past it.
(String, int) _readLiteral(String s, int start) {
  final buf = StringBuffer();
  var i = start + 1;
  var depth = 1;
  final n = s.length;
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (c == 0x5C) {
      // backslash escape
      if (i + 1 >= n) break;
      final e = s.codeUnitAt(i + 1);
      switch (e) {
        case 0x6E: // n
          buf.write('\n');
          i += 2;
          continue;
        case 0x72: // r
          buf.write('\n');
          i += 2;
          continue;
        case 0x74: // t
          buf.write('\t');
          i += 2;
          continue;
        case 0x62: // b
          buf.write('\b');
          i += 2;
          continue;
        case 0x66: // f
          buf.write('\f');
          i += 2;
          continue;
        case 0x28: // (
          buf.write('(');
          i += 2;
          continue;
        case 0x29: // )
          buf.write(')');
          i += 2;
          continue;
        case 0x5C: // \
          buf.write('\\');
          i += 2;
          continue;
        case 0x0A: // line continuation
          i += 2;
          continue;
        default:
          if (e >= 0x30 && e <= 0x37) {
            // Up to three octal digits.
            var oct = 0;
            var k = 0;
            while (k < 3 && i + 1 + k < n) {
              final d = s.codeUnitAt(i + 1 + k);
              if (d < 0x30 || d > 0x37) break;
              oct = oct * 8 + (d - 0x30);
              k++;
            }
            buf.writeCharCode(oct & 0xFF);
            i += 1 + k;
            continue;
          }
          buf.writeCharCode(e);
          i += 2;
          continue;
      }
    }
    if (c == 0x28) {
      depth++;
      buf.write('(');
      i++;
      continue;
    }
    if (c == 0x29) {
      depth--;
      if (depth == 0) {
        i++;
        break;
      }
      buf.write(')');
      i++;
      continue;
    }
    buf.writeCharCode(c);
    i++;
  }
  return (buf.toString(), i);
}

/// Read a `<hex>` string. Returns null when it is empty, since an empty operand
/// should not be added to the pending text.
(String?, int) _readHex(String s, int start) {
  final buf = StringBuffer();
  var i = start + 1;
  final n = s.length;
  while (i < n && s.codeUnitAt(i) != 0x3E) {
    // '>'
    final c = s.codeUnitAt(i);
    if (_isHex(c)) {
      var hi = _hexVal(c);
      i++;
      if (i < n && _isHex(s.codeUnitAt(i))) {
        final lo = _hexVal(s.codeUnitAt(i));
        buf.writeCharCode((hi << 4) | lo);
        i++;
      } else {
        // Odd trailing nibble is left-shifted (low nibble zero), per spec.
        buf.writeCharCode(hi << 4);
      }
    } else {
      i++;
    }
  }
  if (i < n) i++;
  return (buf.isEmpty ? null : buf.toString(), i);
}

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66);

int _hexVal(int c) => c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x57;
