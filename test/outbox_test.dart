import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/sync/outbox.dart';

import 'memory_outbox_store.dart';

void main() {
  late MemoryOutboxStore store;
  late Outbox outbox;
  var now = DateTime.utc(2026, 10, 25, 9);

  setUp(() {
    store = MemoryOutboxStore();
    now = DateTime.utc(2026, 10, 25, 9);
    outbox = Outbox(store, clock: () => now);
  });

  test('pending is oldest day first and honours the limit', () async {
    await outbox.enqueue('2026-10-24', {'drift': 3});
    await outbox.enqueue('2026-10-22', {'drift': 1});
    await outbox.enqueue('2026-10-23', {'drift': 2});
    final all = await outbox.pending();
    expect(all.map((i) => i.day), ['2026-10-22', '2026-10-23', '2026-10-24']);
    expect((await outbox.pending(limit: 2)).map((i) => i.day),
        ['2026-10-22', '2026-10-23']);
    expect(await outbox.pendingCount(), 3);
  });

  test('enqueue replaces an unsent payload for the same day', () async {
    await outbox.enqueue('2026-10-24', {'drift': 3});
    now = now.add(const Duration(hours: 1));
    await outbox.enqueue('2026-10-24', {'drift': 9});
    final items = await outbox.pending();
    expect(items, hasLength(1));
    expect(items.single.payload, {'drift': 9});
    // Still the same queued item, so it keeps its place.
    expect(items.single.createdAt, '2026-10-25T09:00:00.000Z');
  });

  test('markSent removes the day from pending', () async {
    await outbox.enqueue('2026-10-24', {'drift': 3});
    await outbox.markSent('2026-10-24');
    expect(await outbox.pending(), isEmpty);
    final row = store.rows['2026-10-24']!;
    expect(row.sentAt, '2026-10-25T09:00:00.000Z');
    expect(row.attempts, 1);
  });

  test('markFailed keeps the server message and leaves pending', () async {
    await outbox.enqueue('2026-10-24', {'drift': 3});
    await outbox.markFailed('2026-10-24', 'drift must be an integer 0-100');
    expect(await outbox.pending(), isEmpty);
    final failed = await outbox.failed();
    expect(failed.single.lastError, 'drift must be an integer 0-100');
    expect(failed.single.attempts, 1);
  });

  test('a sent or failed day is queued again from scratch', () async {
    await outbox.enqueue('2026-10-23', {'drift': 1});
    await outbox.markSent('2026-10-23');
    await outbox.enqueue('2026-10-24', {'drift': 2});
    await outbox.markFailed('2026-10-24', 'bad');

    now = now.add(const Duration(days: 1));
    await outbox.enqueue('2026-10-23', {'drift': 5});
    await outbox.enqueue('2026-10-24', {'drift': 6});
    final items = await outbox.pending();
    expect(items.map((i) => i.day), ['2026-10-23', '2026-10-24']);
    for (final i in items) {
      expect(i.sentAt, isNull);
      expect(i.lastError, isNull);
      expect(i.attempts, 0);
    }
    expect(await outbox.failed(), isEmpty);
  });

  test('marking an unknown day does nothing', () async {
    await outbox.markSent('2026-01-01');
    await outbox.markFailed('2026-01-01', 'x');
    expect(store.rows, isEmpty);
  });
}
