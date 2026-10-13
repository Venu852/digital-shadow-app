import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class ShadowDb {
  static Database? _db;

  static Future<Database> open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = '${await getDatabasesPath()}/digital_shadow.db';
    final db = await openDatabase(
      path,
      version: 1,
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
      int? sessionId, Map<String, dynamic> summary) async {
    final db = await open();
    await db.insert('windows', {
      'session_id': sessionId,
      'start_ts': summary['window_start_ts'],
      'end_ts': summary['window_end_ts'],
      'features_json': jsonEncode(summary),
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

  static Future<void> deleteAll() async {
    final db = await open();
    await db.delete('windows');
    await db.delete('sessions');
  }
}