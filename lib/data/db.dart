import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class ShadowDb {
  static Database? _db;

  static Future<void> _createUsageTable(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_usage_daily(day TEXT NOT NULL, package TEXT NOT NULL, label TEXT, total_ms INTEGER NOT NULL, sessions INTEGER NOT NULL, last_used_ms INTEGER, category INTEGER, PRIMARY KEY(day, package))');
  }

  static Future<Database> open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = '${await getDatabasesPath()}/digital_shadow.db';
    final db = await openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        try {
          await db.rawQuery('PRAGMA journal_mode=WAL');
        } catch (_) {}
      },
      onCreate: (db, version) async {
        await db.execute(
            'CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, ended_at TEXT)');
        await db.execute(
            'CREATE TABLE windows(id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER, start_ts TEXT, end_ts TEXT, features_json TEXT NOT NULL, score REAL, is_anomaly INTEGER)');
        await db.execute(
            'CREATE INDEX idx_windows_session ON windows(session_id)');
        await _createUsageTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createUsageTable(db);
      },
    );
    _db = db;
    return db;
  }

  static Future<int> startSession(DateTime t) async {
    final db = await open();
    return db.insert('sessions', {'started_at': t.toUtc().toIso8601String()});
  }

  static Future<void> endSession(int id, DateTime t) async {
    final db = await open();
    await db.update('sessions', {'ended_at': t.toUtc().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> insertWindow(
      int? sessionId, Map<String, dynamic> summary,
      {double? score, bool? isAnomaly}) async {
    final db = await open();
    await db.insert('windows', {
      'session_id': sessionId,
      'start_ts': summary['window_start_ts'],
      'end_ts': summary['window_end_ts'],
      'features_json': jsonEncode(summary),
      'score': score,
      'is_anomaly': isAnomaly == null ? null : (isAnomaly ? 1 : 0),
    });
  }

  static Future<int> countWindows() async {
    final db = await open();
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM windows');
    return (r.first['c'] as int?) ?? 0;
  }

  static Future<void> purgeOlderThan(int days) async {
    final db = await open();
    final cutoff =
    DateTime.now().toUtc().subtract(Duration(days: days)).toIso8601String();
    await db.delete('windows', where: 'end_ts < ?', whereArgs: [cutoff]);
  }

  // ---- App usage (daily per-app totals) ----

  static Future<void> upsertUsageDay(
      String day, List<Map<String, Object?>> rows) async {
    final db = await open();
    final batch = db.batch();
    for (final r in rows) {
      batch.insert('app_usage_daily', {...r, 'day': day},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Map<String, Object?>>> usageForDay(String day) async {
    final db = await open();
    return db.query('app_usage_daily',
        where: 'day = ?', whereArgs: [day], orderBy: 'total_ms DESC');
  }

  static Future<List<Map<String, Object?>>> usageDaySummaries() async {
    final db = await open();
    return db.rawQuery(
        'SELECT day, SUM(total_ms) AS total_ms, COUNT(*) AS apps FROM app_usage_daily GROUP BY day ORDER BY day DESC');
  }

  static Future<void> deleteAll() async {
    final db = await open();
    await db.delete('windows');
    await db.delete('sessions');
    await db.delete('app_usage_daily');
  }
}