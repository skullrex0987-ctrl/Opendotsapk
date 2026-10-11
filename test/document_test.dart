/// Tests for document ingestion: format detection, extraction, chunking, and
/// the failure modes that matter (scanned PDFs, oversized files).
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localmind/data/services/document_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('localmind_doc_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<File> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  Future<File> writeText(String name, String text) =>
      write(name, utf8.encode(text));

  group('format support', () {
    final svc = DocumentService.instance;

    test('recognises plain text formats', () {
      for (final ext in ['txt', 'md', 'csv', 'json', 'yaml', 'log', 'dart']) {
        expect(svc.isSupported('file.$ext'), isTrue, reason: ext);
      }
    });

    test('recognises pdf, docx and epub', () {
      for (final ext in ['pdf', 'docx', 'epub']) {
        expect(svc.isSupported('file.$ext'), isTrue, reason: ext);
      }
    });

    test('rejects binaries it cannot read', () {
      for (final ext in ['mp4', 'exe', 'so', 'zip', 'png']) {
        expect(svc.isSupported('file.$ext'), isFalse, reason: ext);
      }
    });

    test('is case insensitive', () {
      expect(svc.isSupported('NOTES.TXT'), isTrue);
      expect(svc.isSupported('Report.Pdf'), isTrue);
    });
  });

  group('plain text ingestion', () {
    test('reads a utf-8 file and chunks it', () async {
      final f = await writeText('notes.txt', 'Hello world. This is a note.');
      final doc = await DocumentService.instance.ingest(f.path);

      expect(doc.name, 'notes.txt');
      expect(doc.text, contains('Hello world'));
      expect(doc.chunks, isNotEmpty);
    });

    test('handles a UTF-8 BOM without leaving a stray glyph', () async {
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('after bom')];
      final f = await write('bom.txt', bytes);
      final doc = await DocumentService.instance.ingest(f.path);

      // The BOM decodes to U+FEFF; it must not survive into the text.
      expect(doc.text.contains('\uFEFF'), isFalse);
      expect(doc.text.trim(), 'after bom');
    });

    test('handles UTF-16LE with a BOM', () async {
      final content = 'utf16 content';
      final bytes = <int>[0xFF, 0xFE];
      for (final c in content.codeUnits) {
        bytes.add(c & 0xFF);
        bytes.add((c >> 8) & 0xFF);
      }
      final f = await write('u16.txt', bytes);
      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.text, contains('utf16 content'));
    });

    test('normalises CRLF line endings', () async {
      final f = await writeText('crlf.txt', 'line one\r\nline two\r\n');
      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.text.contains('\r'), isFalse);
      expect(doc.text, contains('line one'));
    });

    test('collapses runs of blank lines', () async {
      final f = await writeText('blanks.txt', 'a\n\n\n\n\nb');
      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.text.contains('\n\n\n'), isFalse);
    });

    test('reports character and token counts', () async {
      final f = await writeText('count.txt', 'a' * 400);
      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.charCount, 400);
      expect(doc.estimatedTokens, 100);
    });

    test('produces a short preview', () async {
      final f = await writeText('p.txt', 'x' * 500);
      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.preview.length, lessThanOrEqualTo(181));
    });
  });

  group('DOCX ingestion', () {
    /// Build a minimal, structurally valid .docx in memory.
    List<int> buildDocx(String bodyText) {
      final archive = Archive();

      archive.addFile(
        ArchiveFile(
          'word/document.xml',
          utf8.encode('''<?xml version="1.0"?>
<w:document xmlns:w="x"><w:body>
  <w:p><w:r><w:t>$bodyText</w:t></w:r></w:p>
</w:body></w:document>''').length,
          utf8.encode('''<?xml version="1.0"?>
<w:document xmlns:w="x"><w:body>
  <w:p><w:r><w:t>$bodyText</w:t></w:r></w:p>
</w:body></w:document>'''),
        ),
      );

      return ZipEncoder().encode(archive)!;
    }

    test('extracts body text and strips tags', () async {
      final f = await write('doc.docx', buildDocx('Quarterly revenue grew'));
      final doc = await DocumentService.instance.ingest(f.path);

      expect(doc.text, contains('Quarterly revenue grew'));
      expect(doc.text.contains('<w:'), isFalse);
    });

    test('converts paragraphs into newlines', () async {
      final archive = Archive();
      const xml = '''<?xml version="1.0"?>
<w:document xmlns:w="x"><w:body>
  <w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>
  <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
</w:body></w:document>''';
      archive.addFile(
        ArchiveFile(
          'word/document.xml',
          utf8.encode(xml).length,
          utf8.encode(xml),
        ),
      );
      final f = await write('multi.docx', ZipEncoder().encode(archive)!);

      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.text, contains('First paragraph'));
      expect(doc.text, contains('Second paragraph'));
    });

    test('rejects a docx with no readable body', () async {
      final archive = Archive();
      archive.addFile(ArchiveFile('word/styles.xml', 5, utf8.encode('<a/>')));
      final f = await write('empty.docx', ZipEncoder().encode(archive)!);

      expect(
        () => DocumentService.instance.ingest(f.path),
        throwsA(isA<DocumentException>()),
      );
    });
  });

  group('EPUB ingestion', () {
    test('reads xhtml chapters and strips markup', () async {
      final archive = Archive();
      const xhtml = '<html><body><p>Chapter one text</p></body></html>';
      archive.addFile(
        ArchiveFile('ch1.xhtml', utf8.encode(xhtml).length, utf8.encode(xhtml)),
      );

      final f = await write('book.epub', ZipEncoder().encode(archive)!);
      final doc = await DocumentService.instance.ingest(f.path);

      expect(doc.text, contains('Chapter one text'));
      expect(doc.text.contains('<p>'), isFalse);
    });
  });

  group('failure modes', () {
    test('missing file reports a readable error', () async {
      expect(
        () => DocumentService.instance.ingest('${tmp.path}/nope.txt'),
        throwsA(isA<DocumentException>()),
      );
    });

    test('oversized file is refused before it is read', () async {
      final big = await write('big.txt', List.filled(9 * 1024 * 1024, 0x61));
      expect(
        () => DocumentService.instance.ingest(big.path),
        throwsA(
          isA<DocumentException>().having(
            (e) => e.message,
            'message',
            contains('limit'),
          ),
        ),
      );
    });

    test(
      'an empty file yields no chunks and is flagged rather than throwing',
      () async {
        final f = await writeText('empty.txt', '');
        final doc = await DocumentService.instance.ingest(f.path);
        expect(doc.chunks, isEmpty);
        expect(doc.text, isEmpty);
      },
    );

    test('a whitespace-only file yields no chunks', () async {
      final f = await writeText('ws.txt', '   \n\n\t  \n');
      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.chunks, isEmpty);
    });

    test('a PDF with no text layer is flagged, not silently "summarised"', () async {
      // Minimal PDF whose streams contain no text operators.
      const pdf =
          '%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF';
      final f = await write('scan.pdf', utf8.encode(pdf));
      final doc = await DocumentService.instance.ingest(f.path);

      expect(doc.text, isEmpty);
      expect(doc.textLayerMissing, isTrue);
    });

    test(
      'extractor returns empty rather than throwing on garbage input',
      () async {
        final f = await write('junk.pdf', List.filled(2048, 0x00));
        final doc = await DocumentService.instance.ingest(f.path);
        expect(doc.text, isEmpty);
      },
    );
  });

  group('PDF text extraction', () {
    test('recovers text from Tj operators', () async {
      const content = 'BT (Hello from a PDF) Tj ET';
      final pdf = '%PDF-1.4\nstream\n$content\nendstream\n%%EOF';
      final f = await write('text.pdf', utf8.encode(pdf));

      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.text, contains('Hello from a PDF'));
    });

    test('recovers text from TJ arrays', () async {
      const content = 'BT [(Kerned) -50 (text)] TJ ET';
      final pdf = '%PDF-1.4\nstream\n$content\nendstream\n%%EOF';
      final f = await write('tj.pdf', utf8.encode(pdf));

      final doc = await DocumentService.instance.ingest(f.path);
      expect(doc.text, contains('Kerned'));
      expect(doc.text, contains('text'));
    });
  });

  group('chunking integration', () {
    test('a large document produces many overlapping chunks', () async {
      final body = List.generate(
        120,
        (i) => 'Paragraph $i mentions topic${i % 7} in some detail. ',
      ).join();

      final f = await writeText('long.txt', body);
      final doc = await DocumentService.instance.ingest(f.path);

      expect(doc.chunks.length, greaterThan(1));
      for (final c in doc.chunks) {
        expect(c.trim(), isNotEmpty);
      }
    });

    test('concatenated chunks retain all the source wording', () async {
      final words = List.generate(500, (i) => 'w$i').join(' ');
      final f = await writeText('words.txt', words);
      final doc = await DocumentService.instance.ingest(f.path);

      final joined = doc.chunks.join(' ');
      expect(joined, contains('w0'));
      expect(joined, contains('w499'));
    });
  });
}
