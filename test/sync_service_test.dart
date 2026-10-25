import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/sync/outbox.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/sync/sync_service.dart';

import 'memory_outbox_store.dart';

class MemorySettings implements SyncSettings {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(List<String> keys) async =>
      keys.forEach(values.remove);
}

/// Answers putDay from [script] by day; days not in it succeed.
class FakeClient extends ServerClient {
  final Map<String, ApiResult<bool>> script;
  final List<String> calls = [];

  FakeClient(this.script) : super('https://server.test', token: 't');

  @override
  Future<ApiResult<bool>> putDay(
      String day, Map<String, Object?> payload) async {
    calls.add(day);
    return script[day] ?? const ApiResult.ok(false, 200);
  }
}

String day(int n) => '2026-09-${n.toString().padLeft(2, '0')}';

void main() {
  late MemoryOutboxStore store;
  late Outbox outbox;
  late MemorySettings settings;
  late FakeClient client;
  late SyncService sync;
  late DateTime now;

  setUp(() {
    store = MemoryOutboxStore();
    now = DateTime.utc(2026, 10, 25, 9);
    outbox = Outbox(store, clock: () => now);
    settings = MemorySettings()
      ..values.addAll({
        'server_url': 'https://server.test',
        'device_token': 't',
        'sharing_level': 'team_totals',
      });
    client = FakeClient({});
    sync = SyncService(
      outbox: outbox,
      settings: settings,
      clientFor: (url, token) => client,
      clock: () => now,
    );
  });

  Future<void> queue(int days) async {
    for (var i = days; i >= 1; i--) {
      await outbox.enqueue(day(i), {'drift': i});
    }
  }

  test('does nothing when not paired', () async {
    settings.values.remove('device_token');
    await queue(2);
    final r = await sync.run();
    expect(r.state, SyncState.notPaired);
    expect(client.calls, isEmpty);
    expect(settings.values.containsKey('sync_status'), isFalse);
  });

  test('does nothing when sharing is nothing or unset', () async {
    await queue(2);
    settings.values['sharing_level'] = 'nothing';
    expect((await sync.run(force: true)).state, SyncState.sharingOff);
    settings.values.remove('sharing_level');
    expect((await sync.run(force: true)).state, SyncState.sharingOff);
    expect(client.calls, isEmpty);
    expect(await outbox.pendingCount(), 2);
  });

  test('sends oldest first and marks each sent', () async {
    await queue(3);
    final r = await sync.run();
    expect(r.state, SyncState.done);
    expect(r.sent, 3);
    expect(client.calls, [day(1), day(2), day(3)]);
    expect(await outbox.pendingCount(), 0);
    expect(settings.values['sync_status'], SyncStatus.ok);
    expect(settings.values['last_sync_at'], '2026-10-25T09:00:00.000Z');
  });

  test('network error stops and keeps the item', () async {
    await queue(3);
    client.script[day(2)] = const ApiResult.network('Could not reach');
    final r = await sync.run();
    expect(r.state, SyncState.stopped);
    expect(r.sent, 1);
    expect(client.calls, [day(1), day(2)]);
    expect((await outbox.pending()).map((i) => i.day), [day(2), day(3)]);
    expect(await outbox.failed(), isEmpty);
    expect(settings.values['sync_status'], SyncStatus.offline);
  });

  test('403 stops and keeps the item', () async {
    await queue(2);
    client.script[day(1)] = ApiResult.http(403, 'sharing is off');
    final r = await sync.run();
    expect(r.state, SyncState.stopped);
    expect(r.message, 'sharing is off');
    expect(client.calls, [day(1)]);
    expect(await outbox.pendingCount(), 2);
    expect(settings.values['sync_status'], SyncStatus.sharingOff);
  });

  test('401 sets signed_out and later runs do nothing', () async {
    await queue(2);
    client.script[day(1)] = ApiResult.http(401, 'Unauthorized');
    final r = await sync.run();
    expect(r.status, SyncStatus.signedOut);
    expect(settings.values['sync_status'], 'signed_out');
    expect(await outbox.pendingCount(), 2);

    client.script.clear();
    now = now.add(const Duration(minutes: 5));
    expect((await sync.run(force: true)).state, SyncState.signedOut);
    expect(client.calls, [day(1)]);
  });

  test('400 and 413 mark the item failed and continue', () async {
    await queue(4);
    client.script[day(1)] = ApiResult.http(400, 'drift must be an integer 0-100');
    client.script[day(3)] = ApiResult.http(413, 'Body too large');
    final r = await sync.run();
    expect(r.state, SyncState.done);
    expect(r.sent, 2);
    expect(r.failed, 2);
    expect(client.calls, [day(1), day(2), day(3), day(4)]);
    expect(await outbox.pendingCount(), 0);
    final failed = await outbox.failed();
    expect(failed.map((i) => i.lastError),
        ['Body too large', 'drift must be an integer 0-100']);
    expect(settings.values['sync_status'], SyncStatus.someFailed);

    // Failed items are not retried until they are enqueued again.
    now = now.add(const Duration(minutes: 2));
    client.calls.clear();
    await sync.run();
    expect(client.calls, isEmpty);
  });

  test('sends at most 20 days per run', () async {
    await queue(25);
    final r = await sync.run();
    expect(r.sent, 20);
    expect(client.calls.first, day(1));
    expect(client.calls.last, day(20));
    expect(await outbox.pendingCount(), 5);
  });

  test('runs at most once per 60 seconds unless forced', () async {
    await queue(1);
    client.script[day(1)] = const ApiResult.network('Could not reach');
    expect((await sync.run()).state, SyncState.stopped);

    now = now.add(const Duration(seconds: 59));
    expect((await sync.run()).state, SyncState.throttled);
    expect(client.calls, hasLength(1));

    now = now.add(const Duration(seconds: 2));
    expect((await sync.run()).state, SyncState.stopped);
    expect(client.calls, hasLength(2));

    // A button press is not throttled.
    expect((await sync.run(force: true)).state, SyncState.stopped);
    expect(client.calls, hasLength(3));
  });

  test('savePairing and forgetPairing manage the stored credentials',
      () async {
    settings.values['sync_status'] = SyncStatus.signedOut;
    await sync.savePairing(
      serverUrl: 'https://other.test',
      deviceId: 'dev-1',
      deviceToken: 'tok-2',
      username: 'alice',
    );
    expect(await sync.isPaired(), isTrue);
    expect(settings.values['device_token'], 'tok-2');
    expect(settings.values.containsKey('sync_status'), isFalse);

    await sync.forgetPairing();
    expect(await sync.isPaired(), isFalse);
    expect(settings.values.keys, unorderedEquals(['server_url']));
    expect((await sync.run(force: true)).state, SyncState.notPaired);
  });
}
