import 'dart:convert';

import 'package:test_app/data/db.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/sync/sync_service.dart';

/// Storage behind the runner; sqflite on the phone, maps in tests.
abstract class DriftStore {
  /// Totals for every day with any stored data between the two days.
  Future<List<DayRaw>> inputs(String fromDay, String toDay);

  /// True when any unlock was ever recorded on this phone.
  Future<bool> anyUnlocks();

  /// Inserts or replaces the drift_days row of each day.
  Future<void> save(List<DayDrift> days, String builtAt);
}

Map<String, Object?> driftRow(DayDrift d, String builtAt) => {
      'day': d.day,
      'drift': d.drift,
      'levels_json': jsonEncode({
        ...d.levels,
        if (!d.established) 'need_days': d.needDays,
      }),
      'confidence': d.confidence,
      'baseline': d.baseline,
      'dominant': d.dominant,
      'tz': d.tz,
      'built_at': builtAt,
    };

DayDrift driftFromRow(Map<String, Object?> r) {
  final json = (jsonDecode('${r['levels_json']}') as Map).cast<String, Object?>();
  return DayDrift(
    day: r['day'] as String,
    drift: (r['drift'] as num?)?.toInt(),
    levels: {for (final k in signalKeys) k: (json[k] as num?)?.toInt()},
    confidence: ((r['confidence'] as num?) ?? 0).toInt(),
    dominant: '${r['dominant']}',
    tz: '${r['tz']}',
    needDays: ((json['need_days'] as num?) ?? 0).toInt(),
  );
}

class DbDriftStore implements DriftStore {
  const DbDriftStore();

  static int _i(Map<String, Object?> m, String k) =>
      ((m[k] as num?) ?? 0).toInt();

  @override
  Future<List<DayRaw>> inputs(String fromDay, String toDay) async => [
        for (final m in await ShadowDb.driftInputs(fromDay, toDay))
          DayRaw(
            day: m['day'] as String,
            hasBehavior: m['has_behavior'] != null,
            opens: _i(m, 'opens'),
            switches: _i(m, 'switches'),
            wakeups: _i(m, 'wakeups'),
            unlocks: _i(m, 'unlocks'),
            screenMs: _i(m, 'screen_ms'),
            nightScreenMs: _i(m, 'night_ms'),
            appMs: _i(m, 'app_ms'),
            firstOnMin: (m['first_on_min'] as num?)?.toInt(),
            lastOffMin: (m['last_off_min'] as num?)?.toInt(),
          )
      ];

  @override
  Future<bool> anyUnlocks() => ShadowDb.anyUnlocks();

  @override
  Future<void> save(List<DayDrift> days, String builtAt) =>
      ShadowDb.putDriftDays([for (final d in days) driftRow(d, builtAt)]);
}

/// Keys sorted at every level, so equal payloads encode the same way.
String canonicalJson(Object? v) {
  Object? sort(Object? x) => x is Map
      ? {
          for (final k in (x.keys.map((k) => '$k').toList()..sort()))
            k: sort(x[k])
        }
      : x is List
          ? x.map(sort).toList()
          : x;
  return jsonEncode(sort(v));
}

const String demoNotUploaded = 'Demo mode is on, so nothing was uploaded.';

/// Scores the recent completed days, queues the changed ones and uploads.
class DriftRunner {
  static const int days = 14;

  final DriftStore store;
  final SyncService sync;
  final DateTime Function() _clock;
  final Duration Function(String day) _offsetFor;

  /// True while demo mode is on: nothing is scored, stored or uploaded.
  final bool Function() _isDemo;

  DriftRunner({
    required this.store,
    required this.sync,
    DateTime Function()? clock,
    Duration Function(String day)? offsetFor,
    bool Function()? isDemo,
  })  : _clock = clock ?? DateTime.now,
        _offsetFor = offsetFor ?? localOffsetAt,
        _isDemo = isDemo ?? (() => DemoMode.on);

  static DriftRunner? _instance;

  static DriftRunner get instance => _instance ??=
      DriftRunner(store: const DbDriftStore(), sync: SyncService.instance);

  static String _dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Rebuilds drift_days for the last [days] completed days, newest first.
  Future<List<DayDrift>> rebuild() async {
    if (_isDemo()) return const [];
    final now = _clock();
    final yesterday = addDays(_dayKey(now), -1);
    final raw = await store.inputs(
        addDays(yesterday, -(days - 1) - baselineWindowDays), yesterday);
    final scored = scoreRecentDays(raw, yesterday,
        count: days,
        useUnlocks: await store.anyUnlocks(),
        offsetFor: _offsetFor);
    await store.save(scored, now.toUtc().toIso8601String());
    return scored;
  }

  /// Queues each established day whose payload differs from the one last
  /// queued or sent for it. Returns how many were queued; nothing is queued
  /// when the phone is not paired or sharing is off.
  Future<int> enqueueChanged(List<DayDrift> scored) async {
    if (_isDemo()) return 0;
    if (!await sync.isPaired()) return 0;
    if (!SyncService.sharingLevels
        .contains(await sync.settings.get('sharing_level'))) {
      return 0;
    }
    var queued = 0;
    for (final d in scored) {
      final payload = d.payload();
      if (payload == null) continue;
      final old = await sync.outbox.store.get(d.day);
      String? oldJson;
      try {
        oldJson = old == null ? null : canonicalJson(old.payload);
      } catch (_) {
        // A damaged stored payload is replaced.
      }
      if (oldJson == canonicalJson(payload)) continue;
      await sync.outbox.enqueue(d.day, payload);
      queued++;
    }
    return queued;
  }

  /// Scores and queues (best effort), then lets the sync service upload.
  Future<SyncResult> run({bool force = false}) async {
    if (_isDemo()) {
      return const SyncResult(SyncState.stopped, message: demoNotUploaded);
    }
    try {
      await enqueueChanged(await rebuild());
    } catch (_) {
      // Scoring is best effort; anything already queued is still sent.
    }
    return sync.run(force: force);
  }
}
