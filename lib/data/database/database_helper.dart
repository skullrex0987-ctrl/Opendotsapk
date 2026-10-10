/// Database helper for SQLite operations
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../core/constants/app_constants.dart';

class DatabaseHelper {
  static Database? _database;
  static const String _dbName = 'localmind.db';
  
  // Table names
  static const String tableMessages = 'messages';
  static const String tableVectors = 'vectors';
  static const String tableNotes = 'notes';
  static const String tableActivityLog = 'activity_log';
  static const String tableUserPreferences = 'user_preferences';
  
  // Get database instance
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }
  
  // Initialize database
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    
    return openDatabase(
      path,
      version: 1,
      onCreate: _createTables,
    );
  }
  
  // Create all tables
  Future<void> _createTables(Database db, int version) async {
    // Messages table
    await db.execute('''
      CREATE TABLE $tableMessages (
        id TEXT PRIMARY KEY,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        embedding_id INTEGER
      )
    ''');
    
    // Vectors table (sqlite-vec virtual table).
    // NOTE: requires the sqlite-vec extension to be loaded before this runs.
    await db.execute('''
      CREATE VIRTUAL TABLE $tableVectors USING vec0(
        embedding float[${AppConstants.vectorDimension}]
      )
    ''');
    
    // Notes table
    await db.execute('''
      CREATE TABLE $tableNotes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    
    // Activity log table
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
    
    // User preferences table
    await db.execute('''
      CREATE TABLE $tableUserPreferences (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    
    // Create indexes
    await db.execute('''
      CREATE INDEX idx_messages_timestamp ON $tableMessages(timestamp)
    ''');
    await db.execute('''
      CREATE INDEX idx_messages_role ON $tableMessages(role)
    ''');
  }
  
  // Insert message
  Future<String> insertMessage({
    required String id,
    required String role,
    required String content,
    required int timestamp,
  }) async {
    final db = await database;
    await db.insert(tableMessages, {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp,
    });
    return id;
  }
  
  // Get recent messages
  Future<List<Map<String, dynamic>>> getRecentMessages({
    int limit = 50,
    String? role,
  }) async {
    final db = await database;
    final query = role != null
        ? 'SELECT * FROM $tableMessages WHERE role = ? ORDER BY timestamp DESC LIMIT ?'
        : 'SELECT * FROM $tableMessages ORDER BY timestamp DESC LIMIT ?';
    
    final result = role != null
        ? await db.query(tableMessages, 
            columns: null, 
            where: 'role = ?', 
            whereArgs: [role, limit],
            orderBy: 'timestamp DESC'
          )
        : await db.rawQuery(query, [limit]);
    
    return result.reversed.toList();
  }
  
  // Insert embedding
  Future<int> insertEmbedding({
    required String messageId,
    required List<double> embedding,
  }) async {
    final db = await database;
    return await db.insert(tableVectors, {
      'id': messageId,
      'embedding': embedding.toList(),
    });
  }
  
  // Search similar embeddings
  Future<List<Map<String, dynamic>>> searchSimilar({
    required List<double> queryVector,
    int limit = 5,
    double? minScore,
  }) async {
    final db = await database;
    
    final result = await db.rawQuery('''
      SELECT m.* FROM $tableMessages m
      JOIN $tableVectors v ON m.id = v.id
      ORDER BY v.embedding <=> ?
      LIMIT ?
    ''', [
      queryVector.map((e) => e.toString()).join(','),
      limit,
    ]);
    
    return result;
  }
  
  // Insert note
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
      'content': content,
      'created_at': timestamp,
      'updated_at': timestamp,
    });
    return id;
  }
  
  // Get notes
  Future<List<Map<String, dynamic>>> getNotes({String? query}) async {
    final db = await database;
    if (query != null) {
      return await db.query(
        tableNotes,
        where: 'title LIKE ? OR content LIKE ?',
        whereArgs: ['%$query%', '%$query%'],
        orderBy: 'updated_at DESC',
      );
    }
    return await db.query(tableNotes, orderBy: 'updated_at DESC');
  }
  
  // Delete note
  Future<int> deleteNote(String id) async {
    final db = await database;
    return await db.delete(
      tableNotes,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
  
  // Insert activity log
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
      'params': params,
      'result': result,
      'status': status,
      'timestamp': timestamp,
      'permission_level': permissionLevel,
    });
    return id;
  }
  
  // Get activity log
  Future<List<Map<String, dynamic>>> getActivityLog({int limit = 100}) async {
    final db = await database;
    return await db.query(
      tableActivityLog,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
  }
  
  // Save preference
  Future<void> savePreference(String key, String value) async {
    final db = await database;
    await db.insert(
      tableUserPreferences,
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  
  // Get preference
  Future<String?> getPreference(String key) async {
    final db = await database;
    final result = await db.query(
      tableUserPreferences,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (result.isNotEmpty) {
      return result.first['value'] as String?;
    }
    return null;
  }
  
  // Close database
  Future<void> close() async {
    final db = await database;
    db.close();
  }
}
