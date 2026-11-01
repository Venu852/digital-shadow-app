import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/demo/synthetic_drift_repository.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_repository.dart';
import 'package:test_app/drift/drift_runner.dart';
import 'package:test_app/suggest/suggest_store.dart';
import 'package:test_app/suggest/suggestion_service.dart';
import 'package:test_app/sync/outbox.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/sync/sync_service.dart';

import 'memory_outbox_store.dart';

class MemoryDriftStore implements DriftStore {
  final Map<String, DayRaw> raw = {};
  final List<DayDrift> saved = [];
  int reads = 0;

  @override
  Future<List<DayRaw>> inputs(String fromDay, String toDay) async {
    reads++;
    return raw.values.toList();
  }

  @override
  Future<bool> anyUnlocks() async => true;

  @override
  Future<void> save(List<DayDrift> days, String builtAt) async =>
      saved.addAll(days);
}

class MemorySettings implements SyncSettings {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> remove(List<String> keys) async {
    writes++;
    keys.forEach(values.remove);
  }
}

class CountingClient extends ServerClient {
  int calls = 0;

  CountingClient() : super('https://server.test', token: 't');

  @override
  Future<ApiResult<bool>> putDay(
    String day,
    Map<String, Object?> payload,
  ) async {
    calls++;
    return const ApiResult.ok(false, 200);
  }
}

DayRaw raw(String d) => DayRaw(
  day: d,
  opens: 50,
  switches: 100,
  unlocks: 50,
  screenMs: 200 * 60000,
  appMs: 180 * 60000,
  firstOnMin: 420,
  lastOffMin: 1380,
);

void main() {
  final now = DateTime(2026, 11, 1, 9);
  late MemoryDriftStore store;
  late MemoryOutboxStore outboxStore;
  late MemorySettings settings;
  late CountingClient client;
  late SyncService sync;

  setUp(() {
    store = MemoryDriftStore();
    for (var i = 1; i <= 20; i++) {
      final d = addDays('2026-11-01', -i);
      store.raw[d] = raw(d);
    }
    outboxStore = MemoryOutboxStore();
    settings = MemorySettings()
      ..values.addAll({
        'server_url': 'https://server.test',
        'device_token': 't',
        'sharing_level': 'my_trend',
      });
    client = CountingClient();
    sync = SyncService(
      outbox: Outbox(outboxStore, clock: () => now),
      settings: settings,
      clientFor: (url, token) => client,
      clock: () => now,
    );
  });

  tearDown(() => DemoMode.set(false));

  Future<void> expectNothingHappened(DriftRunner runner) async {
    // A day queued before demo mode was turned on stays queued.
    await sync.outbox.enqueue('2026-10-01', {'drift': 10});
    final writesBefore = settings.writes;
    final r = await runner.run(force: true);
    expect(r.state, SyncState.stopped);
    expect(r.message, demoNotUploaded);
    expect(await runner.rebuild(), isEmpty);
    expect(await runner.enqueueChanged([scoreDay('2026-10-31', const {})]), 0);
    expect(store.reads, 0);
    expect(store.saved, isEmpty);
    expect(outboxStore.rows.keys, ['2026-10-01']);
    expect(outboxStore.rows['2026-10-01']!.sentAt, isNull);
    expect(client.calls, 0);
    expect(settings.writes, writesBefore);
    expect(settings.values.containsKey('last_sync_at'), isFalse);
  }

  test('the runner and sync do nothing while demo mode is on', () async {
    await expectNothingHappened(
      DriftRunner(
        store: store,
        sync: sync,
        clock: () => now,
        isDemo: () => true,
      ),
    );
  });

  test('the runner follows the app-wide switch', () async {
    final runner = DriftRunner(store: store, sync: sync, clock: () => now);
    DemoMode.set(true);
    await expectNothingHappened(runner);

    DemoMode.set(false);
    final r = await runner.run(force: true);
    expect(r.state, SyncState.done);
    expect(store.saved, isNotEmpty);
    expect(client.calls, greaterThan(0));
  });

  test('demo mode swaps in simulated data and an in-memory store', () {
    expect(DemoMode.on, isFalse);
    expect(DemoMode.repository, isA<DbDriftRepository>());
    expect(DemoMode.store, isA<DbSuggestStore>());

    DemoMode.set(true);
    expect(DemoMode.repository, isA<SyntheticDriftRepository>());
    expect(DemoMode.repository.simulated, isTrue);
    final memory = DemoMode.store;
    expect(memory, isA<MemorySuggestStore>());
    expect(identical(DemoMode.store, memory), isTrue);

    DemoMode.set(false);
    expect(DemoMode.repository, isA<DbDriftRepository>());
    DemoMode.set(true);
    expect(identical(DemoMode.store, memory), isFalse);
  });

  test('suggestions in demo mode are kept in memory only', () async {
    SuggestionService.resetOpenCheck();
    DemoMode.set(true);
    final service = SuggestionService(
      repository: DemoMode.repository,
      store: DemoMode.store,
    );
    final v = await service.load();
    // The story's last day: drift 52 led by switching and night.
    expect(v.offered.map((s) => s.key), ['sig:switching', 'sig:night']);
    await service.tryForWeek(v.offered.first);
    await service.notNow(v.offered.last);

    final memory = DemoMode.store as MemorySuggestStore;
    expect(memory.experimentRows, hasLength(1));
    expect(memory.stateRows.keys, ['sig:switching', 'sig:night']);

    final after = await service.load();
    expect(after.running, hasLength(1));
    // The night nudge comes from the story's late-night minutes.
    expect(after.offered.map((s) => s.key), ['nudge:night']);

    DemoMode.set(false);
    DemoMode.set(true);
    expect((DemoMode.store as MemorySuggestStore).experimentRows, isEmpty);
  });
}
