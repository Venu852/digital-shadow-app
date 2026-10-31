import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class ShadowDb {
  static Database? _db;

  /// Settings written by the server sync; cleared with the outbox.
  static const List<String> syncSettingKeys = [
    'server_url',
    'device_id',
    'device_token',
    'paired_username',
    'sharing_level',
    'last_sync_at',
    'sync_status',
  ];

  static Future<void> _createUsageTable(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_usage_daily(day TEXT NOT NULL, package TEXT NOT NULL, label TEXT, total_ms INTEGER NOT NULL, sessions INTEGER NOT NULL, last_used_ms INTEGER, category INTEGER, PRIMARY KEY(day, package))');
  }

  static Future<void> _createSettingsTable(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS settings(setting_key TEXT PRIMARY KEY, setting_value TEXT)');
  }

  static Future<void> _createHourlyTable(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_usage_hourly(day TEXT NOT NULL, hour INTEGER NOT NULL, package TEXT NOT NULL, total_ms INTEGER NOT NULL, PRIMARY KEY(day, hour, package))');
  }

  static Future<void> _createBehaviorTable(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS usage_behavior_hourly(day TEXT NOT NULL, hour INTEGER NOT NULL, opens INTEGER NOT NULL, switches INTEGER NOT NULL, wakeups INTEGER NOT NULL, unlocks INTEGER NOT NULL, screen_ms INTEGER NOT NULL DEFAULT 0, notifications INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, hour))');
  }

  static Future<void> _createOutboxTable(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS outbox(day TEXT PRIMARY KEY, payload_json TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, created_at TEXT NOT NULL, sent_at TEXT)');
  }

  static Future<void> _createDriftTables(Database db) async {
    await db.execute(
        'CREATE TABLE IF NOT EXISTS day_rhythm(day TEXT PRIMARY KEY, first_on_min INTEGER, last_off_min INTEGER)');
    // levels_json holds the six levels (null = no usable baseline) and, for
    // calibrating days, need_days.
    await db.execute(
        'CREATE TABLE IF NOT EXISTS drift_days(day TEXT PRIMARY KEY, drift INTEGER, levels_json TEXT, confidence INTEGER, baseline TEXT, dominant TEXT, tz TEXT, built_at TEXT NOT NULL)');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS checkins(day TEXT PRIMARY KEY, score INTEGER NOT NULL CHECK(score BETWEEN 1 AND 5), created_at TEXT NOT NULL)');
  }

  static Future<Database> open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = '${await getDatabasesPath()}/digital_shadow.db';
    final db = await openDatabase(
      path,
      version: 9,
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
        await _createSettingsTable(db);
        await _createHourlyTable(db);
        await _createBehaviorTable(db);
        await _createOutboxTable(db);
        await _createDriftTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) await _createSettingsTable(db);
        if (oldVersion < 4) await _createHourlyTable(db);
        if (oldVersion < 5) await _createBehaviorTable(db);
        if (oldVersion < 6) {
          try {
            await db.execute(
                'ALTER TABLE usage_behavior_hourly ADD COLUMN screen_ms INTEGER NOT NULL DEFAULT 0');
          } catch (_) {
            // Column already exists (table was just created with it).
          }
        }
        if (oldVersion < 7) {
          try {
            await db.execute(
                'ALTER TABLE usage_behavior_hourly ADD COLUMN notifications INTEGER NOT NULL DEFAULT 0');
          } catch (_) {
            // Column already exists (table was just created with it).
          }
        }
        if (oldVersion < 8) await _createOutboxTable(db);
        if (oldVersion < 9) await _createDriftTables(db);
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
    await db.transaction((txn) async {
      await txn.delete('app_usage_daily', where: 'day = ?', whereArgs: [day]);
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('app_usage_daily', {...r, 'day': day},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
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

  static Future<List<Map<String, Object?>>> usageTopApps(
      String fromDay, String toDay) async {
    final db = await open();
    return db.rawQuery(
        'SELECT package, MAX(label) AS label, SUM(total_ms) AS total_ms, SUM(sessions) AS sessions, MAX(category) AS category FROM app_usage_daily WHERE day >= ? AND day <= ? GROUP BY package ORDER BY total_ms DESC',
        [fromDay, toDay]);
  }

  static Future<String?> getSetting(String key) async {
    final db = await open();
    final r = await db.query('settings',
        where: 'setting_key = ?', whereArgs: [key], limit: 1);
    return r.isEmpty ? null : r.first['setting_value'] as String?;
  }

  static Future<void> setSetting(String key, String value) async {
    final db = await open();
    await db.insert('settings', {'setting_key': key, 'setting_value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, Object?>>> usageRows(
      String fromDay, String toDay) async {
    final db = await open();
    return db.query('app_usage_daily',
        columns: [
          'day',
          'package',
          'label',
          'total_ms',
          'sessions',
          'category'
        ],
        where: 'day >= ? AND day <= ?',
        whereArgs: [fromDay, toDay]);
  }

  static Future<Map<String, String>> getSettingsByPrefix(String prefix) async {
    final db = await open();
    final r = await db.query('settings',
        where: 'setting_key LIKE ?', whereArgs: ['$prefix%']);
    final out = <String, String>{};
    for (final m in r) {
      final k = m['setting_key'] as String?;
      final v = m['setting_value'] as String?;
      if (k != null && v != null) out[k] = v;
    }
    return out;
  }

  static Future<void> replaceUsageHourly(
      String day, List<Map<String, Object?>> rows) async {
    final db = await open();
    await db.transaction((txn) async {
      await txn.delete('app_usage_hourly', where: 'day = ?', whereArgs: [day]);
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('app_usage_hourly', {...r, 'day': day});
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<List<int>> hourlyTotals(String fromDay, String toDay) async {
    final db = await open();
    final r = await db.rawQuery(
        'SELECT hour, SUM(total_ms) AS total_ms FROM app_usage_hourly WHERE day >= ? AND day <= ? GROUP BY hour',
        [fromDay, toDay]);
    final out = List<int>.filled(24, 0);
    for (final m in r) {
      final h = (m['hour'] as num?)?.toInt();
      if (h != null && h >= 0 && h < 24) {
        out[h] = ((m['total_ms'] as num?) ?? 0).toInt();
      }
    }
    return out;
  }

  static Future<void> replaceBehaviorDay(
      String day, List<Map<String, Object?>> rows) async {
    final db = await open();
    await db.transaction((txn) async {
      await txn.delete('usage_behavior_hourly',
          where: 'day = ?', whereArgs: [day]);
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('usage_behavior_hourly', {...r, 'day': day});
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<Map<String, int>> behaviorTotals(
      String fromDay, String toDay) async {
    final db = await open();
    final r = await db.rawQuery(
        'SELECT COALESCE(SUM(opens),0) AS opens, COALESCE(SUM(switches),0) AS switches, COALESCE(SUM(wakeups),0) AS wakeups, COALESCE(SUM(unlocks),0) AS unlocks, COALESCE(SUM(screen_ms),0) AS screen_ms, COALESCE(SUM(notifications),0) AS notifications, COUNT(DISTINCT day) AS days FROM usage_behavior_hourly WHERE day >= ? AND day <= ?',
        [fromDay, toDay]);
    final a = await db.rawQuery(
        'SELECT COUNT(DISTINCT package) AS apps FROM app_usage_hourly WHERE day >= ? AND day <= ? AND total_ms > 0',
        [fromDay, toDay]);
    int g(Map<String, Object?> m, String k) => ((m[k] as num?) ?? 0).toInt();
    final row = r.first;
    return {
      'opens': g(row, 'opens'),
      'switches': g(row, 'switches'),
      'wakeups': g(row, 'wakeups'),
      'unlocks': g(row, 'unlocks'),
      'screen_ms': g(row, 'screen_ms'),
      'notifications': g(row, 'notifications'),
      'days': g(row, 'days'),
      'apps': g(a.first, 'apps'),
    };
  }

  static Future<List<Map<String, Object?>>> behaviorRows(
      String fromDay, String toDay) async {
    final db = await open();
    return db.query('usage_behavior_hourly',
        where: 'day >= ? AND day <= ?', whereArgs: [fromDay, toDay]);
  }

  static Future<List<Map<String, Object?>>> hourlyForeground(
      String fromDay, String toDay) async {
    final db = await open();
    return db.rawQuery(
        'SELECT day, hour, SUM(total_ms) AS ms, COUNT(DISTINCT package) AS apps FROM app_usage_hourly WHERE day >= ? AND day <= ? AND total_ms > 0 GROUP BY day, hour',
        [fromDay, toDay]);
  }

  static Future<List<Map<String, Object?>>> windowsBetween(
      String startIso, String endIso) async {
    final db = await open();
    return db.query('windows',
        columns: ['id', 'features_json'],
        where: 'end_ts >= ? AND end_ts < ?',
        whereArgs: [startIso, endIso]);
  }

  static Future<void> updateWindowFeatures(
      List<MapEntry<int, String>> updates) async {
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final u in updates) {
        batch.update('windows', {'features_json': u.value},
            where: 'id = ?', whereArgs: [u.key]);
      }
      await batch.commit(noResult: true);
    });
  }

  static Future<void> applyRetention(int days) async {
    final db = await open();
    final now = DateTime.now();
    final cut = DateTime(now.year, now.month, now.day - days);
    final cutDay = '${cut.year.toString().padLeft(4, '0')}-'
        '${cut.month.toString().padLeft(2, '0')}-'
        '${cut.day.toString().padLeft(2, '0')}';
    final cutIso =
    now.toUtc().subtract(Duration(days: days)).toIso8601String();
    await db.delete('windows', where: 'end_ts < ?', whereArgs: [cutIso]);
    await db.delete('sessions', where: 'started_at < ?', whereArgs: [cutIso]);
    await db.delete('app_usage_daily', where: 'day < ?', whereArgs: [cutDay]);
    await db.delete('app_usage_hourly', where: 'day < ?', whereArgs: [cutDay]);
    await db.delete('usage_behavior_hourly',
        where: 'day < ?', whereArgs: [cutDay]);
    await db.delete('day_rhythm', where: 'day < ?', whereArgs: [cutDay]);
    await db.delete('drift_days', where: 'day < ?', whereArgs: [cutDay]);
    await db.delete('checkins', where: 'day < ?', whereArgs: [cutDay]);
  }

  static Future<void> deleteAllSettings() async {
    final db = await open();
    await db.delete('settings');
  }

  static Future<List<Map<String, Object?>>> windowsSince(String iso) async {
    final db = await open();
    return db.query('windows',
        columns: ['end_ts', 'score', 'is_anomaly', 'features_json'],
        where: 'end_ts >= ?',
        whereArgs: [iso],
        orderBy: 'end_ts ASC');
  }

  static Future<List<Map<String, Object?>>> recentSessions(int limit) async {
    final db = await open();
    return db.rawQuery(
        'SELECT s.id AS id, s.started_at AS started_at, s.ended_at AS ended_at, COUNT(w.id) AS windows, COALESCE(SUM(CASE WHEN w.is_anomaly = 1 THEN 1 ELSE 0 END), 0) AS flagged FROM sessions s LEFT JOIN windows w ON w.session_id = s.id GROUP BY s.id ORDER BY s.started_at DESC LIMIT ?',
        [limit]);
  }

  static Future<void> deleteAll() async {
    final db = await open();
    await db.delete('windows');
    await db.delete('sessions');
    await db.delete('app_usage_daily');
    await db.delete('app_usage_hourly');
    await db.delete('usage_behavior_hourly');
    await db.delete('settings',
        where: 'setting_key = ?', whereArgs: ['motion_baseline']);
    await db.delete('outbox');
    await db.delete('day_rhythm');
    await db.delete('drift_days');
    await db.delete('checkins');
    await deleteSettings(syncSettingKeys);
  }

  static Future<void> deleteSettings(List<String> keys) async {
    if (keys.isEmpty) return;
    final db = await open();
    await db.delete('settings',
        where: 'setting_key IN (${List.filled(keys.length, '?').join(',')})',
        whereArgs: keys);
  }

  // ---- Outbox (daily summaries waiting for upload) ----

  static Future<Map<String, Object?>?> outboxGet(String day) async {
    final db = await open();
    final r = await db.query('outbox',
        where: 'day = ?', whereArgs: [day], limit: 1);
    return r.isEmpty ? null : r.first;
  }

  static Future<void> outboxPut(Map<String, Object?> row) async {
    final db = await open();
    await db.insert('outbox', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, Object?>>> outboxPending(int? limit) async {
    final db = await open();
    return db.query('outbox',
        where: 'sent_at IS NULL AND last_error IS NULL',
        orderBy: 'day ASC',
        limit: limit);
  }

  static Future<List<Map<String, Object?>>> outboxFailed() async {
    final db = await open();
    return db.query('outbox',
        where: 'sent_at IS NULL AND last_error IS NOT NULL',
        orderBy: 'day DESC');
  }

  // ---- Daily drift ----

  static Future<void> putDayRhythm(
      String day, int firstOnMin, int lastOffMin) async {
    final db = await open();
    await db.insert('day_rhythm',
        {'day': day, 'first_on_min': firstOnMin, 'last_off_min': lastOffMin},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Per-day totals for the drift engine: behaviour sums (with screen time
  /// in hours 0-4), app minutes and the day's rhythm.
  static Future<List<Map<String, Object?>>> driftInputs(
      String fromDay, String toDay) async {
    final db = await open();
    final b = await db.rawQuery(
        'SELECT day, SUM(opens) AS opens, SUM(switches) AS switches, SUM(wakeups) AS wakeups, SUM(unlocks) AS unlocks, SUM(screen_ms) AS screen_ms, SUM(CASE WHEN hour < 5 THEN screen_ms ELSE 0 END) AS night_ms FROM usage_behavior_hourly WHERE day >= ? AND day <= ? GROUP BY day',
        [fromDay, toDay]);
    final a = await db.rawQuery(
        'SELECT day, SUM(total_ms) AS app_ms FROM app_usage_hourly WHERE day >= ? AND day <= ? GROUP BY day',
        [fromDay, toDay]);
    final r = await db.query('day_rhythm',
        where: 'day >= ? AND day <= ?', whereArgs: [fromDay, toDay]);
    final out = <String, Map<String, Object?>>{};
    Map<String, Object?> row(Object? day) =>
        out.putIfAbsent('$day', () => {'day': '$day'});
    for (final m in b) {
      row(m['day']).addAll({...m, 'has_behavior': 1});
    }
    for (final m in a) {
      row(m['day'])['app_ms'] = m['app_ms'];
    }
    for (final m in r) {
      row(m['day']).addAll(
          {'first_on_min': m['first_on_min'], 'last_off_min': m['last_off_min']});
    }
    return out.values.toList();
  }

  static Future<bool> anyUnlocks() async {
    final db = await open();
    final r = await db.rawQuery(
        'SELECT 1 FROM usage_behavior_hourly WHERE unlocks > 0 LIMIT 1');
    return r.isNotEmpty;
  }

  static Future<void> putDriftDays(List<Map<String, Object?>> rows) async {
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.insert('drift_days', r,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Newest first.
  static Future<List<Map<String, Object?>>> driftDays(
      String fromDay, String toDay) async {
    final db = await open();
    return db.query('drift_days',
        where: 'day >= ? AND day <= ?',
        whereArgs: [fromDay, toDay],
        orderBy: 'day DESC');
  }

  static Future<void> putCheckin(String day, int score) async {
    final db = await open();
    await db.insert(
        'checkins',
        {
          'day': day,
          'score': score,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, int>> checkins(String fromDay, String toDay) async {
    final db = await open();
    final r = await db.query('checkins',
        where: 'day >= ? AND day <= ?', whereArgs: [fromDay, toDay]);
    return {
      for (final m in r) '${m['day']}': ((m['score'] as num?) ?? 0).toInt()
    };
  }
}
