/// SQLite persistence: messages, embeddings, notes, documents, activity log.
///
/// ## Why this file was rewritten
///
/// The previous version declared its vector store as a `vec0` virtual table:
///
/// ```sql
/// CREATE VIRTUAL TABLE vectors USING vec0(embedding float[384])
/// ```
///
/// `vec0` only exists when the **sqlite-vec extension is loaded**. `sqflite`
/// cannot load extensions, and nothing in the app ever called
/// `loadExtension`. So `onCreate` threw on the very first launch and the whole
/// database — memory, notes, activity log — was dead on arrival. The insert
/// also wrote an `id` column that `vec0` does not have, and search used the
/// extension-only `<=>` operator.
///
/// Embeddings are now stored as plain `BLOB`s and similarity is computed in
/// Dart. For the scale this app operates at (thousands of memories, 384 floats
/// each) that is a few milliseconds of arithmetic, and it has three concrete
/// advantages over an extension: it cannot fail to load, it needs no extra
/// native library in the APK, and it lets retrieval fuse vector similarity with
/// keyword scores in a single pass, which is what actually improves answers.
///
/// ## Retrieval
///
/// [searchHybrid] runs BM25 keyword scoring and cosine similarity over the same
/// candidate set, normalises both, fuses them, then optionally applies a
/// maximal-marginal-relevance pass to drop near-duplicate hits. Small on-device
/// models are far more sensitive to junk in the context window than large ones,
/// so removing redundancy matters more here than it does server-side.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/security/crypto_box.dart';
import '../../core/utils/log.dart';
import '../../core/utils/text_utils.dart';
import '../../core/constants/app_constants.dart';

class DatabaseHelper {
  DatabaseHelper._();

  static DatabaseHelper? _instance;
  static DatabaseHelper get instance => _instance ??= DatabaseHelper._();

  static Database? _database;

  static const String _dbName = 'localmind.db';

  /// Bumped from 1: the schema changed from a broken `vec0` table to real
  /// tables. `onUpgrade` rebuilds the vector store and keeps messages.
  static const int _schemaVersion = 2;

  static const String tableMessages = 'messages';
  static const String tableVectors = 'vectors';
  static const String tableNotes = 'notes';
  static const String tableActivityLog = 'activity_log';
  static const String tableUserPreferences = 'user_preferences';
  static const String tableDocuments = 'documents';
  static const String tableChunks = 'chunks';

  /// Substituted for an encrypted column that could not be decrypted with the
  /// current key. Non-empty on purpose: handing back `''` for an unreadable row
  /// both hides the data loss and, if the user edits and saves that row, would
  /// overwrite the still-intact ciphertext with an empty string.
  static const String unreadablePlaceholder = '[unreadable]';

  /// Cached corpus statistics for BM25. Recomputed lazily and invalidated on
  /// write, because a stale IDF makes keyword ranking quietly wrong.
  _CorpusStats? _corpus;

  /// Decoded memory rows used by search, cached alongside [_corpus].
  ///
  /// [_loadCandidates] is O(every row): one SQLite read, one AES-GCM decrypt
  /// and one tokenisation per memory. Doing that again for every keystroke of a
  /// search is the single most expensive thing in the RAG path, and the answer
  /// cannot change between two searches with no write in between — which is
  /// exactly when [_invalidateIndex] has not run.
  ///
  /// Bounded: a corpus larger than [_maxCachedCandidates] rows is deliberately
  /// *not* retained, because holding thousands of decrypted passages plus their
  /// vectors and term-frequency maps resident is the kind of memory pressure
  /// that gets an Android app killed. Above the cap the behaviour is exactly
  /// what it always was — computed per query — just not faster.
  static const int _maxCachedCandidates = 512;

  List<_Candidate>? _candidates;

  /// Memoised preferences, and when they were read.
  ///
  /// `user_preferences` is a tiny key/value table — every key this app reads is
  /// a fixed name, and the whole table is a few hundred bytes. Reading it in
  /// one query and serving from a map turns a dozen sequential round trips
  /// (what a settings load does) into one, and makes every subsequent read free.
  ///
  /// Correctness rests on [savePreference] being the only writer, and on this
  /// class invalidating the memo in [wipe] and [close]. The TTL is a belt-and-
  /// braces measure for a write that somehow bypasses this class.
  static const Duration preferenceCacheTtl = Duration(seconds: 30);

  Map<String, String>? _preferences;
  DateTime? _preferencesReadAt;

  /// Invalidate the retrieval index (decoded candidates *and* BM25 stats).
  ///
  /// One method rather than two assignments so the two can never drift apart —
  /// a corpus whose stats came from one set of rows and whose candidates came
  /// from another would rank against numbers that do not describe it.
  void _invalidateIndex() {
    _corpus = null;
    _candidates = null;
  }

  // ------------------------------------------------------------------ open

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _init();
    return _database!;
  }

  Future<Database> _init() async {
    final dir = await getDatabasesPath();
    final path = join(dir, _dbName);

    return openDatabase(
      path,
      version: _schemaVersion,
      onCreate: (db, v) => _createTables(db),
      onUpgrade: _upgrade,
      onConfigure: (db) async {
        // Foreign keys are off by default in SQLite; the chunks table relies
        // on them to cascade when a document is deleted.
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _upgrade(Database db, int from, int to) async {
    Log.w('database upgrade $from -> $to');

    // This used to DROP $tableVectors and $tableChunks unconditionally on every
    // version bump, then recreate them empty. Every embedding and every
    // document chunk the user had was silently discarded by a routine app
    // update — their whole searchable index, gone, with no warning.
    //
    // The tables are created with IF NOT EXISTS, so an unchanged schema needs
    // no rebuild at all. The one genuine exception is the legacy `vec0` virtual
    // table, which is not a real table and cannot be altered, so it is detected
    // and only that one is replaced. $tableChunks is left alone.
    await _dropLegacyVec0IfPresent(db);

    await _createVectorTables(db);
    await _createDocumentTables(db);
  }

  /// Drops the vector table only when it is the legacy `vec0` virtual table.
  ///
  /// A normal table is deliberately left in place so its rows survive the
  /// upgrade. Without this distinction the only options were "drop everything"
  /// or "never fix a bad schema".
  Future<void> _dropLegacyVec0IfPresent(Database db) async {
    final rows = await db.rawQuery(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
      [tableVectors],
    );
    if (rows.isEmpty) return;

    final sql = '${rows.first['sql'] ?? ''}'.toLowerCase();
    if (!sql.contains('vec0')) return;

    Log.w('$tableVectors is a legacy vec0 table; replacing it');
    await db.execute('DROP TABLE IF EXISTS $tableVectors');
  }

  Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE $tableMessages (
        id TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        conversation_id TEXT,
        embedding_id INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE $tableNotes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $tableActivityLog (
        id TEXT PRIMARY KEY,
        tool_name TEXT NOT NULL,
        params TEXT,
        result TEXT,
        status TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        permission_level TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE $tableUserPreferences (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_messages_timestamp ON $tableMessages(timestamp)',
    );
    await db.execute(
      'CREATE INDEX idx_messages_conversation ON $tableMessages(conversation_id)',
    );
    await db.execute(
      'CREATE INDEX idx_activity_timestamp ON $tableActivityLog(timestamp)',
    );

    await _createVectorTables(db);
    await _createDocumentTables(db);
  }

  /// The memory store: one row per embedded passage.
  ///
  /// `embedding` is a BLOB of little-endian float32 values, which is the same
  /// layout ONNX hands us — no conversion cost on write.
  Future<void> _createVectorTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableVectors (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id TEXT NOT NULL,
        source_type TEXT NOT NULL DEFAULT 'message',
        text TEXT NOT NULL,
        embedding BLOB NOT NULL,
        dim INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vectors_source '
      'ON $tableVectors(source_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_vectors_type '
      'ON $tableVectors(source_type)',
    );
  }

  Future<void> _createDocumentTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableDocuments (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        path TEXT,
        mime TEXT,
        char_count INTEGER NOT NULL DEFAULT 0,
        chunk_count INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableChunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        document_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        text TEXT NOT NULL,
        embedding BLOB NOT NULL,
        dim INTEGER NOT NULL,
        FOREIGN KEY (document_id) REFERENCES $tableDocuments(id)
          ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_chunks_doc ON $tableChunks(document_id)',
    );
  }

  // -------------------------------------------------------------- messages

  Future<String> insertMessage({
    required String id,
    required String role,
    required String content,
    required int timestamp,
    String? conversationId,
  }) async {
    final db = await database;
    await db.insert(tableMessages, {
      'id': id,
      'role': role,
      // Encrypted at rest when a keystore key is available.
      'content': await CryptoBox.instance.encrypt(content),
      'timestamp': timestamp,
      'conversation_id': conversationId,
    });
    _invalidateIndex();
    return id;
  }

  Future<List<Map<String, dynamic>>> getRecentMessages({
    int limit = 50,
    String? role,
    bool decrypt = true,
  }) async {
    final db = await database;
    final where = role != null ? 'WHERE role = ?' : '';
    final args = role != null ? <Object?>[role] : <Object?>[];

    final rows = await db.rawQuery(
      'SELECT * FROM $tableMessages $where ORDER BY timestamp DESC LIMIT ?',
      [...args, limit],
    );

    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      out.add(await _decryptRow(r, 'content', decrypt));
    }
    return out.reversed.toList();
  }

  Future<int> deleteAllMessages() async {
    final db = await database;
    _invalidateIndex();
    return db.delete(tableMessages);
  }

  // ------------------------------------------------------------- memories

  /// Store an embedded passage. [vector] must match [AppConstants.vectorDimension]
  /// or the row is rejected, because a mismatched vector would silently poison
  /// every later similarity computation.
  Future<int> insertMemory({
    required String sourceId,
    required String text,
    required List<double> vector,
    String sourceType = 'message',
  }) async {
    if (vector.length != AppConstants.vectorDimension) {
      Log.w(
        'refusing to store memory: expected '
        '${AppConstants.vectorDimension} dims, got ${vector.length}',
      );
      throw ArgumentError('embedding dimension mismatch');
    }

    final db = await database;
    _invalidateIndex();
    return db.insert(tableVectors, {
      'source_id': sourceId,
      'source_type': sourceType,
      'text': await CryptoBox.instance.encrypt(text),
      'embedding': encodeVector(vector),
      'dim': vector.length,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> deleteMemory(int id) async {
    final db = await database;
    _invalidateIndex();
    return db.delete(tableVectors, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteAllMemories() async {
    final db = await database;
    _invalidateIndex();
    return db.delete(tableVectors);
  }

  Future<int> memoryCount() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) c FROM $tableVectors');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Every stored memory, newest first, decrypted.
  Future<List<Map<String, dynamic>>> getMemories({int limit = 500}) async {
    final db = await database;
    final rows = await db.query(
      tableVectors,
      orderBy: 'created_at DESC',
      limit: limit,
    );

    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = await _decryptRow(r, 'text', true);
      m.remove('embedding'); // never ship the raw blob to the UI
      out.add(m);
    }
    return out;
  }

  /// Vector-only search. Kept for callers that explicitly want it; the agent
  /// uses [searchHybrid].
  Future<List<MemoryHit>> searchSimilar({
    required List<double> queryVector,
    int limit = 5,
    double minScore = 0.0,
  }) async {
    final all = await _loadCandidates();
    final hits = <MemoryHit>[];
    for (final c in all) {
      final s = TextUtils.cosine(queryVector, c.vector);
      if (s >= minScore) {
        hits.add(
          MemoryHit(memory: c, vectorScore: s, keywordScore: 0, score: s),
        );
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }

  /// Fused retrieval: BM25 keyword score + cosine similarity + MMR diversity.
  ///
  /// [queryEmbedding] may be null, in which case it degrades to keyword-only
  /// rather than returning nothing — important because the ONNX encoder is
  /// optional and may not be loaded.
  Future<List<MemoryHit>> searchHybrid({
    required String query,
    List<double>? queryEmbedding,
    int limit = 5,
    int candidatePool = 60,
    double vectorWeight = 0.6,
    double keywordWeight = 0.4,
    bool diversify = true,
  }) async {
    final candidates = await _loadCandidates();
    if (candidates.isEmpty) return const [];

    final queryTerms = TextUtils.tokenize(query)
        .where((t) => !TextUtils.stopWords.contains(t))
        .toList();
    if (queryTerms.isEmpty && queryEmbedding == null) return const [];

    final stats = _corpus ??= _computeStats(candidates);

    // ---- keyword: BM25 -------------------------------------------------
    final rawKeyword = <int, double>{};
    if (queryTerms.isNotEmpty) {
      for (final c in candidates) {
        var score = 0.0;
        for (final term in queryTerms) {
          final tf = c.termFreq[term];
          if (tf == null) continue;
          final idf = stats.idf(term);
          final denom =
              tf +
              stats.k1 *
                  (1 - stats.b + stats.b * (c.tokenCount / stats.avgLength));
          score += idf * ((tf * (stats.k1 + 1)) / denom);
        }
        if (score > 0) rawKeyword[c.id] = score;
      }
    }

    // ---- vector: cosine ------------------------------------------------
    final rawVector = <int, double>{};
    if (queryEmbedding != null) {
      for (final c in candidates) {
        rawVector[c.id] = TextUtils.cosine(queryEmbedding, c.vector);
      }
    }

    final maxKeyword = rawKeyword.values.fold<double>(0, math.max);
    final maxVector = rawVector.values.fold<double>(0, math.max);

    // ---- fuse ----------------------------------------------------------
    final fused = <MemoryHit>[];
    for (final c in candidates) {
      final kw = maxKeyword > 0 ? (rawKeyword[c.id] ?? 0) / maxKeyword : 0.0;
      final vs = maxVector > 0 ? (rawVector[c.id] ?? 0) / maxVector : 0.0;

      // When one signal is missing entirely, use the other at full weight so
      // results are not uniformly halved.
      double combined;
      if (queryEmbedding == null) {
        combined = kw;
      } else if (queryTerms.isEmpty) {
        combined = vs;
      } else {
        combined = vectorWeight * vs + keywordWeight * kw;
      }

      if (combined <= 0) continue;
      fused.add(
        MemoryHit(
          memory: c,
          vectorScore: vs,
          keywordScore: kw,
          score: combined,
        ),
      );
    }

    fused.sort((a, b) => b.score.compareTo(a.score));
    var pool = fused.take(candidatePool).toList();

    if (diversify && pool.length > limit) {
      pool = _mmr(pool, limit, lambda: 0.75);
    }

    return pool.take(limit).toList();
  }

  /// Maximal Marginal Relevance: pick hits that are relevant but not redundant.
  ///
  /// `lambda` = 1.0 is pure relevance, 0.0 is pure diversity. 0.75 keeps a
  /// relevant ordering while dropping the near-identical neighbours that
  /// otherwise fill a small model's context with the same sentence four times.
  static List<MemoryHit> _mmr(
    List<MemoryHit> pool,
    int limit, {
    double lambda = 0.75,
  }) {
    final selected = <MemoryHit>[];
    final remaining = List<MemoryHit>.from(pool);

    while (remaining.isNotEmpty && selected.length < limit) {
      MemoryHit? best;
      var bestScore = double.negativeInfinity;

      for (final cand in remaining) {
        var maxSim = 0.0;
        for (final s in selected) {
          final sim = TextUtils.cosine(cand.memory.vector, s.memory.vector);
          if (sim > maxSim) maxSim = sim;
        }
        final mmr = lambda * cand.score - (1 - lambda) * maxSim;
        if (mmr > bestScore) {
          bestScore = mmr;
          best = cand;
        }
      }

      if (best == null) break;
      selected.add(best);
      remaining.remove(best);
    }

    return selected;
  }

  /// Load every memory row and decode its vector once.
  ///
  /// Memoised between writes (see [_maxCachedCandidates]): this is the whole
  /// per-query cost of retrieval — a table read, an AES-GCM decrypt and a
  /// tokenisation for every memory in the index — and it does not change
  /// between two searches.
  Future<List<_Candidate>> _loadCandidates() async {
    final cached = _candidates;
    if (cached != null) return cached;
    final loaded = await _readCandidates();
    if (loaded.length <= _maxCachedCandidates) _candidates = loaded;
    return loaded;
  }

  /// Read and decode every memory row. Never cached directly; see
  /// [_loadCandidates].
  Future<List<_Candidate>> _readCandidates() async {
    final db = await database;
    final rows = await db.query(tableVectors);

    final out = <_Candidate>[];
    for (final r in rows) {
      try {
        final blob = r['embedding'] as Uint8List?;
        if (blob == null) continue;
        final vector = decodeVector(blob);
        final dim = (r['dim'] as int?) ?? vector.length;
        if (vector.length != dim) continue;

        final decoded = await CryptoBox.instance.decryptChecked('${r['text']}');
        if (decoded is DecryptFailure) {
          // A row we cannot read cannot be scored; indexing the placeholder
          // would make it match queries it has nothing to do with.
          Log.w('skipping unreadable memory row: ${decoded.reason}');
          continue;
        }
        // Deliberately a positive check rather than relying on flow promotion
        // after the `continue` above: the rest of this file pattern-matches on
        // the sealed result, and this form compiles everywhere.
        if (decoded is! DecryptedValue) {
          Log.w('skipping memory row with an unexpected decrypt result');
          continue;
        }
        final text = decoded.value;
        final tokens = TextUtils.tokenize(text);

        out.add(
          _Candidate(
            id: r['id'] as int,
            sourceId: '${r['source_id']}',
            sourceType: '${r['source_type'] ?? 'message'}',
            text: text,
            vector: vector,
            termFreq: TextUtils.termFrequencies(tokens),
            tokenCount: tokens.length,
          ),
        );
      } catch (e) {
        Log.w('skipping unreadable memory row: $e');
      }
    }
    return out;
  }

  static _CorpusStats _computeStats(List<_Candidate> docs) {
    final df = <String, int>{};
    var total = 0;
    for (final d in docs) {
      total += d.tokenCount;
      for (final t in d.termFreq.keys) {
        df[t] = (df[t] ?? 0) + 1;
      }
    }
    return _CorpusStats(
      docCount: docs.length,
      avgLength: docs.isEmpty ? 1 : total / docs.length,
      docFreq: df,
    );
  }

  // ------------------------------------------------------------- documents

  Future<void> insertDocument({
    required String id,
    required String name,
    String? path,
    String mime = 'text/plain',
    int charCount = 0,
    int chunkCount = 0,
  }) async {
    final db = await database;
    await db.insert(tableDocuments, {
      'id': id,
      'name': name,
      'path': path,
      'mime': mime,
      'char_count': charCount,
      'chunk_count': chunkCount,
      'added_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertChunks({
    required String documentId,
    required List<String> texts,
    required List<List<double>> vectors,
  }) async {
    if (texts.length != vectors.length) {
      throw ArgumentError('chunk/text count mismatch');
    }
    final db = await database;

    // Encrypt every chunk concurrently instead of one await at a time.
    //
    // Each AES-GCM encryption is independent and yields on its own asynchronous
    // work, so running them in sequence made ingesting a document cost the sum
    // of every chunk's encryption; `Future.wait` overlaps them. Order is
    // preserved by construction (`Future.wait` returns results in input order),
    // so ordinal `i` is still paired with `texts[i]` exactly as before.
    final encrypted = await Future.wait(texts.map(CryptoBox.instance.encrypt));

    final batch = db.batch();
    for (var i = 0; i < texts.length; i++) {
      batch.insert(tableChunks, {
        'document_id': documentId,
        'ordinal': i,
        'text': encrypted[i],
        'embedding': encodeVector(vectors[i]),
        'dim': vectors[i].length,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getDocuments() async {
    final db = await database;
    return db.query(tableDocuments, orderBy: 'added_at DESC');
  }

  Future<int> deleteDocument(String id) async {
    final db = await database;
    return db.delete(tableDocuments, where: 'id = ?', whereArgs: [id]);
  }

  /// Search inside documents by keyword.
  ///
  /// The chunk text column is encrypted at rest (see [insertChunks]), so the
  /// SQL `LIKE` this used to run could never match anything a user typed — the
  /// search was looking for their words inside ciphertext. Matching therefore
  /// happens after decryption.
  ///
  /// Only the two columns needed are read, and the await inside the loop yields
  /// between rows so a large index does not lock the frame. It is still O(all
  /// chunks) per search; a plaintext blind index would make it O(matches) and is
  /// the right next step if document counts grow.
  Future<List<Map<String, dynamic>>> searchDocuments(String query) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];

    final db = await database;

    final chunks = await db.query(
      tableChunks,
      columns: ['document_id', 'text'],
    );

    final matchedIds = <String>{};
    for (final row in chunks) {
      final plain = await _decryptTextColumn('${row['text'] ?? ''}');
      if (plain.toLowerCase().contains(needle)) {
        matchedIds.add('${row['document_id']}');
      }
    }
    if (matchedIds.isEmpty) return const [];

    final docs = await db.query(
      tableDocuments,
      where: 'id IN (${List.filled(matchedIds.length, '?').join(',')})',
      whereArgs: matchedIds.toList(),
      orderBy: 'added_at DESC',
      limit: 20,
    );

    return [for (final r in docs) Map<String, dynamic>.from(r)];
  }

  Future<List<Map<String, dynamic>>> getChunksFor(String documentId) async {
    final db = await database;
    final rows = await db.query(
      tableChunks,
      where: 'document_id = ?',
      whereArgs: [documentId],
      orderBy: 'ordinal',
    );

    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = await _decryptRow(r, 'text', true);
      m.remove('embedding');
      out.add(m);
    }
    return out;
  }

  // ------------------------------------------------------------------ notes

  Future<String> insertNote({
    required String id,
    required String title,
    required String content,
    required int timestamp,
  }) async {
    final db = await database;
    await db.insert(tableNotes, {
      'id': id,
      'title': title,
      'content': await CryptoBox.instance.encrypt(content),
      'created_at': timestamp,
      'updated_at': timestamp,
    });
    return id;
  }

  Future<List<Map<String, dynamic>>> getNotes({String? query}) async {
    final db = await database;
    final rows = query != null && query.isNotEmpty
        ? await db.query(
            tableNotes,
            where: 'title LIKE ?',
            whereArgs: ['%$query%'],
            orderBy: 'updated_at DESC',
          )
        : await db.query(tableNotes, orderBy: 'updated_at DESC');

    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      out.add(await _decryptRow(r, 'content', true));
    }
    return out;
  }

  Future<int> deleteNote(String id) async {
    final db = await database;
    return db.delete(tableNotes, where: 'id = ?', whereArgs: [id]);
  }

  // ----------------------------------------------------------- activity log

  /// Rows kept in the activity log.
  ///
  /// The log is append-only machine output — one row per tool call — and
  /// nothing in the app ever prunes it, so a long-running install grew without
  /// bound. The Activity screen only ever reads the newest
  /// [getActivityLog] default of 100, and `clearActivityLog` is a user control,
  /// so retaining a generous window keeps everything the UI can reach and
  /// discards history no interface can display.
  ///
  /// Deliberately not aggressive: 1000 entries is far more than any person
  /// scrolls through, and trimming is skipped entirely below this count so the
  /// common case (a fresh install) never pays for the delete.
  static const int activityLogRetention = 1000;

  /// Store a tool-call record.
  ///
  /// Writes, then trims to [activityLogRetention]. The trim is a delete rather
  /// than a count-and-check so it cannot be skipped by a concurrent insert, and
  /// it targets only rows outside the newest window — the rows the UI shows are
  /// never at risk.
  Future<String> insertActivityLog({
    required String id,
    required String toolName,
    required String params,
    required String result,
    required String status,
    required int timestamp,
    required String permissionLevel,
  }) async {
    final db = await database;
    await db.insert(tableActivityLog, {
      'id': id,
      'tool_name': toolName,
      // These were written as plaintext while getActivityLog decrypted them on
      // the way out, so the log both leaked its contents at rest and failed to
      // read back correctly. Write and read now agree.
      'params': await CryptoBox.instance.encrypt(params),
      'result': await CryptoBox.instance.encrypt(result),
      'status': status,
      'timestamp': timestamp,
      'permission_level': permissionLevel,
    });
    await _trimActivityLog(db);
    return id;
  }

  /// Delete activity rows older than the newest [activityLogRetention].
  ///
  /// The `NOT IN (SELECT ...)` form is one statement regardless of how many
  /// rows exist, so there is no read-then-delete race between deciding what is
  /// old and removing it.
  Future<void> _trimActivityLog(Database db) async {
    await db.rawDelete(
      'DELETE FROM $tableActivityLog WHERE id NOT IN '
      '(SELECT id FROM $tableActivityLog ORDER BY timestamp DESC LIMIT ?)',
      [activityLogRetention],
    );
  }

  Future<List<Map<String, dynamic>>> getActivityLog({int limit = 100}) async {
    final db = await database;
    final rows = await db.query(
      tableActivityLog,
      orderBy: 'timestamp DESC',
      limit: limit,
    );

    final out = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r);
      m['params'] = await _decryptTextColumn('${r['params'] ?? ''}');
      m['result'] = await _decryptTextColumn('${r['result'] ?? ''}');
      out.add(m);
    }
    return out;
  }

  Future<int> clearActivityLog() async {
    final db = await database;
    return db.delete(tableActivityLog);
  }

  // ------------------------------------------------------------ preferences

  /// Persist one preference.
  ///
  /// Writes through to [preferenceCache] rather than invalidating it, so a
  /// screen that saves a setting and immediately reads it back gets the value
  /// it just wrote rather than a re-query.
  Future<void> savePreference(String key, String value) async {
    final db = await database;
    await db.insert(tableUserPreferences, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    (_preferences ??= <String, String>{})[key] = value;
    _preferencesReadAt = DateTime.now();
  }

  /// Read one preference, or null when it has never been set.
  ///
  /// Served from the memoised table rather than issued as its own query. The
  /// table is small and this method is called in loops by anything loading
  /// settings, so the difference between "one query for the whole table" and
  /// "one query per key" is the difference between a first frame that arrives
  /// promptly and one that waits on a dozen sequential SQLite round trips.
  Future<String?> getPreference(String key) async {
    final prefs = await _preferenceSnapshot();
    return prefs[key];
  }

  /// Read many preferences at once.
  ///
  /// Equivalent to awaiting [getPreference] for each key, but a caller that
  /// knows its keys up front can collapse the whole set into a single
  /// snapshot — [preferenceCache] makes that free once the table has been read
  /// once. Keys with no stored value are absent from the result, exactly as
  /// [getPreference] returns null for them.
  Future<Map<String, String>> getPreferences(Iterable<String> keys) async {
    final prefs = await _preferenceSnapshot();
    final out = <String, String>{};
    for (final key in keys) {
      final value = prefs[key];
      if (value != null) out[key] = value;
    }
    return out;
  }

  /// The memoised preference table, or null before the first read.
  ///
  /// Exposed for diagnostics and so a caller that knows it has written to the
  /// table by another route can check what this class currently believes. It is
  /// a snapshot, not a live view: prefer [getPreference].
  Map<String, String>? get preferenceCache => _preferences;

  /// Drop the memoised preferences, forcing the next read back to the database.
  ///
  /// Called by [wipe] and [close]. Exposed so anything that writes to the
  /// preferences table by another route can keep the memo honest.
  void invalidatePreferenceCache() {
    _preferences = null;
    _preferencesReadAt = null;
  }

  /// The whole preference table, read at most once per
  /// [preferenceCacheTtl].
  Future<Map<String, String>> _preferenceSnapshot() async {
    final cached = _preferences;
    final readAt = _preferencesReadAt;
    final now = DateTime.now();
    if (cached != null &&
        readAt != null &&
        now.difference(readAt) < preferenceCacheTtl) {
      return cached;
    }

    final db = await database;
    final rows = await db.query(
      tableUserPreferences,
      columns: ['key', 'value'],
    );
    final out = <String, String>{};
    for (final row in rows) {
      final key = row['key'];
      final value = row['value'];
      if (key is String && value is String) out[key] = value;
    }
    _preferences = out;
    _preferencesReadAt = now;
    return out;
  }

  // ------------------------------------------------------------- utilities

  /// Rebuild the whole database. Used by "Erase all data".
  Future<void> wipe() async {
    final db = await database;
    for (final t in [
      tableChunks,
      tableDocuments,
      tableVectors,
      tableMessages,
      tableNotes,
      tableActivityLog,
      tableUserPreferences,
    ]) {
      await db.delete(t);
    }
    _invalidateIndex();
    // Every preference row is gone, so anything this class remembers about
    // them is now wrong. Leaving the memo in place would hand back settings
    // the user had just erased.
    invalidatePreferenceCache();
    Log.w('database wiped');
  }

  /// Row counts for every user-facing table.
  ///
  /// One query rather than six: each `SELECT COUNT(*)` is a separate round trip
  /// through the platform channel, and this is called from screens that are
  /// already trying to paint promptly. SQLite evaluates the scalar
  /// sub-selects in a single pass over an index-free `COUNT(*)` each, which is
  /// far cheaper than six statements being queued and awaited in sequence.
  Future<Map<String, int>> stats() async {
    final db = await database;
    final r = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM $tableMessages)    AS messages,
        (SELECT COUNT(*) FROM $tableVectors)     AS memories,
        (SELECT COUNT(*) FROM $tableNotes)       AS notes,
        (SELECT COUNT(*) FROM $tableDocuments)   AS documents,
        (SELECT COUNT(*) FROM $tableChunks)      AS chunks,
        (SELECT COUNT(*) FROM $tableActivityLog) AS activity
    ''');
    if (r.isEmpty) return const {};
    final row = r.first;
    int at(String key) => (row[key] as int?) ?? 0;

    return {
      'messages': at('messages'),
      'memories': at('memories'),
      'notes': at('notes'),
      'documents': at('documents'),
      'chunks': at('chunks'),
      'activity': at('activity'),
    };
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
    // A closed database means the next one may hold completely different rows
    // (or may not exist at all, on a wiped install), so nothing memoised here
    // is safe to keep.
    _invalidateIndex();
    invalidatePreferenceCache();
  }

  // ------------------------------------------------- float32 <-> BLOB codec

  /// Encode as little-endian float32. ONNX output is already float32, so this
  /// is a direct copy rather than a lossy conversion to double and back.
  static Uint8List encodeVector(List<double> v) {
    final bytes = Uint8List(v.length * 4);
    final view = ByteData.view(bytes.buffer);
    for (var i = 0; i < v.length; i++) {
      view.setFloat32(i * 4, v[i], Endian.little);
    }
    return bytes;
  }

  static List<double> decodeVector(Uint8List bytes) {
    if (bytes.lengthInBytes % 4 != 0) return const [];
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final out = List<double>.filled(bytes.lengthInBytes ~/ 4, 0);
    for (var i = 0; i < out.length; i++) {
      out[i] = view.getFloat32(i * 4, Endian.little);
    }
    return out;
  }

  /// Decrypt one column of a row map, returning a copy.
  static Future<Map<String, dynamic>> _decryptRow(
    Map<String, dynamic> row,
    String column,
    bool decrypt,
  ) async {
    final out = Map<String, dynamic>.from(row);
    if (!decrypt) return out;
    final raw = row[column];
    if (raw is String && CryptoBox.isEncrypted(raw)) {
      final result = await CryptoBox.instance.decryptChecked(raw);
      out[column] = switch (result) {
        DecryptedValue(:final value) => value,
        DecryptFailure(:final reason) => _markUnreadable(column, reason),
      };
    }
    return out;
  }

  /// Log an unreadable encrypted column and return the placeholder for it, so a
  /// decrypt failure is visible in diagnostics instead of silently reading as a
  /// blank field.
  static String _markUnreadable(String column, DecryptFailureReason reason) {
    Log.e('unreadable encrypted column "$column": $reason');
    return unreadablePlaceholder;
  }

  /// Decrypt a nullable TEXT column (activity log params/result). An unreadable
  /// value becomes [unreadablePlaceholder] rather than an empty string, which
  /// is what distinguishes it from a genuinely empty field.
  static Future<String> _decryptTextColumn(String raw) async {
    final result = await CryptoBox.instance.decryptChecked(raw);
    return switch (result) {
      DecryptedValue(:final value) => value,
      DecryptFailure(:final reason) => _markUnreadable('text', reason),
    };
  }

  /// Debug helper: dump a table as JSON. Never used in the UI path.
  static String debugJson(List<Map<String, dynamic>> rows) =>
      const JsonEncoder.withIndent('  ').convert(rows);
}

/// A stored memory, decoded for scoring.
class _Candidate {
  final int id;
  final String sourceId;
  final String sourceType;
  final String text;
  final List<double> vector;
  final Map<String, int> termFreq;
  final int tokenCount;

  const _Candidate({
    required this.id,
    required this.sourceId,
    required this.sourceType,
    required this.text,
    required this.vector,
    required this.termFreq,
    required this.tokenCount,
  });
}

/// BM25 corpus statistics, cached until the next write.
class _CorpusStats {
  final int docCount;
  final double avgLength;
  final Map<String, int> docFreq;

  // Standard BM25 free parameters.
  final double k1 = 1.5;
  final double b = 0.75;

  const _CorpusStats({
    required this.docCount,
    required this.avgLength,
    required this.docFreq,
  });

  /// Robertson-Sparck Jones IDF with the +1 floor so a term appearing in every
  /// document contributes ~0 instead of going negative.
  double idf(String term) {
    final df = docFreq[term] ?? 0;
    final n = math.max(docCount, 1);
    final r = (n - df + 0.5) / (df + 0.5);
    return math.log(1 + math.max(r, 0));
  }
}

/// A scored search result, carrying both component scores so the UI can show
/// *why* something matched.
class MemoryHit {
  final _Candidate memory;
  final double vectorScore;
  final double keywordScore;
  final double score;

  const MemoryHit({
    required this.memory,
    required this.vectorScore,
    required this.keywordScore,
    required this.score,
  });

  String get text => memory.text;
  String get sourceId => memory.sourceId;
  String get sourceType => memory.sourceType;

  /// Short badge for the memory list: "semantic", "keyword", or "both".
  String get matchKind {
    if (vectorScore > 0.3 && keywordScore > 0.15) return 'both';
    if (keywordScore > 0.15) return 'keyword';
    return 'semantic';
  }
}
