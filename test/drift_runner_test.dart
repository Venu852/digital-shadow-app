import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_runner.dart';
import 'package:test_app/sync/outbox.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/sync/sync_service.dart';

import 'drift_contract.dart';
import 'memory_outbox_store.dart';

class MemoryDriftStore implements DriftStore {
  final Map<String, DayRaw> raw = {};
  final Map<String, DayDrift> saved = {};
  bool unlocks = true;

  @override
  Future<List<DayRaw>> inputs(String fromDay, String toDay) async => raw.values
      .where((r) => r.day.compareTo(fromDay) >= 0 && r.day.compareTo(toDay) <= 0)
      .toList();

  @override
  Future<bool> anyUnlocks() async => unlocks;

  @override
  Future<void> save(List<DayDrift> days, String builtAt) async {
    for (final d in days) {
      saved[d.day] = d;
    }
  }
}

class MemorySettings implements SyncSettings {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(List<String> keys) async => keys.forEach(values.remove);
}

class FakeClient extends ServerClient {
  final List<Map<String, Object?>> bodies = [];
  final List<String> calls = [];

  FakeClient() : super('https://server.test', token: 't');

  @override
  Future<ApiResult<bool>> putDay(
      String day, Map<String, Object?> payload) async {
    calls.add(day);
    bodies.add(payload);
    return const ApiResult.ok(false, 200);
  }
}

DayRaw day(String d, {int switches = 100}) => DayRaw(
      day: d,
      opens: 50,
      switches: switches,
      unlocks: 50,
      screenMs: 200 * 60000,
      nightScreenMs: 10 * 60000,
      appMs: 180 * 60000,
      firstOnMin: 420,
      lastOffMin: 1380,
    );

void main() {
  late MemoryDriftStore store;
  late MemoryOutboxStore outboxStore;
  late MemorySettings settings;
  late FakeClient client;
  late DriftRunner runner;
  final now = DateTime(2026, 10, 31, 9);
  const yesterday = '2026-10-30';

  setUp(() {
    store = MemoryDriftStore();
    outboxStore = MemoryOutboxStore();
    settings = MemorySettings()
      ..values.addAll({
        'server_url': 'https://server.test',
        'device_token': 't',
        'sharing_level': 'my_trend',
      });
    client = FakeClient();
    runner = DriftRunner(
      store: store,
      sync: SyncService(
        outbox: Outbox(outboxStore, clock: () => now),
        settings: settings,
        clientFor: (url, token) => client,
        clock: () => now,
      ),
      clock: () => now,
      offsetFor: (_) => const Duration(hours: 5, minutes: 30),
    );
    // 16 days of history ending yesterday, and today (never scored).
    for (var i = 0; i < 16; i++) {
      final d = addDays(yesterday, -i);
      store.raw[d] = day(d);
    }
    store.raw['2026-10-31'] = day('2026-10-31', switches: 999);
  });

  test('scores 14 completed days and uploads only established ones', () async {
    final r = await runner.run(force: true);
    expect(store.saved.keys, hasLength(14));
    expect(store.saved.containsKey('2026-10-31'), isFalse);
    expect(store.saved.keys.reduce((a, b) => a.compareTo(b) > 0 ? a : b),
        yesterday);

    // Days with fewer than 5 earlier days stay calibrating and are never
    // queued: the oldest data day is 2026-10-15, so 10-17..10-19 calibrate.
    final established =
        store.saved.values.where((d) => d.established).map((d) => d.day);
    expect(established, hasLength(14 - 3));
    expect(r.state, SyncState.done);
    expect(r.sent, 11);
    expect(client.calls.toSet(), established.toSet());
    for (final b in client.bodies) {
      expect(validateDayPayload(b), isNull);
    }
  });

  test('enqueues only payloads that changed', () async {
    final first = await runner.enqueueChanged(await runner.rebuild());
    expect(first, 11);
    await runner.sync.run(force: true);
    expect(client.calls, hasLength(11));

    // Same data: nothing new is queued or sent.
    expect(await runner.enqueueChanged(await runner.rebuild()), 0);
    client.calls.clear();
    await runner.run(force: true);
    expect(client.calls, isEmpty);

    // The newest day changes: only it is queued again.
    store.raw[yesterday] = day(yesterday, switches: 160);
    expect(await runner.enqueueChanged(await runner.rebuild()), 1);
    await runner.sync.run(force: true);
    expect(client.calls, [yesterday]);
    expect((client.bodies.last['levels'] as Map)['switching'], 100);

    // A pending day with the same payload is not queued twice.
    store.raw[yesterday] = day(yesterday, switches: 130);
    expect(await runner.enqueueChanged(await runner.rebuild()), 1);
    expect(await runner.enqueueChanged(await runner.rebuild()), 0);
    expect((await outboxStore.pending()).map((i) => i.day), [yesterday]);
  });

  test('nothing is queued when sharing is nothing or unset', () async {
    settings.values['sharing_level'] = 'nothing';
    final r = await runner.run(force: true);
    expect(r.state, SyncState.sharingOff);
    expect(store.saved, hasLength(14));
    expect(outboxStore.rows, isEmpty);

    settings.values.remove('sharing_level');
    await runner.run(force: true);
    expect(outboxStore.rows, isEmpty);
    expect(client.calls, isEmpty);
  });

  test('nothing is queued when not paired', () async {
    settings.values.remove('device_token');
    final r = await runner.run(force: true);
    expect(r.state, SyncState.notPaired);
    expect(store.saved, hasLength(14));
    expect(outboxStore.rows, isEmpty);
  });
}
