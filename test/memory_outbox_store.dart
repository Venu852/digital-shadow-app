import 'package:test_app/sync/outbox.dart';

/// In-memory [OutboxStore] for tests, ordered like the sqflite store.
class MemoryOutboxStore implements OutboxStore {
  final Map<String, OutboxItem> rows = {};

  @override
  Future<OutboxItem?> get(String day) async => rows[day];

  @override
  Future<void> put(OutboxItem item) async => rows[item.day] = item;

  @override
  Future<List<OutboxItem>> pending({int? limit}) async {
    final out = rows.values
        .where((i) => i.sentAt == null && i.lastError == null)
        .toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    return limit == null ? out : out.take(limit).toList();
  }

  @override
  Future<List<OutboxItem>> failed() async =>
      rows.values.where((i) => i.failed).toList()
        ..sort((a, b) => b.day.compareTo(a.day));
}
