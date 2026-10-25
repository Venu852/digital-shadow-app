import 'dart:convert';

/// One day's summary waiting to be uploaded (or already sent).
class OutboxItem {
  final String day;
  final String payloadJson;
  final int attempts;
  final String? lastError;
  final String createdAt;
  final String? sentAt;

  const OutboxItem({
    required this.day,
    required this.payloadJson,
    this.attempts = 0,
    this.lastError,
    required this.createdAt,
    this.sentAt,
  });

  /// Rejected by the server; it is retried only after it is enqueued again.
  bool get failed => sentAt == null && lastError != null;

  Map<String, Object?> get payload =>
      (jsonDecode(payloadJson) as Map).cast<String, Object?>();

  OutboxItem copyWith({
    int? attempts,
    String? lastError,
    String? sentAt,
  }) =>
      OutboxItem(
        day: day,
        payloadJson: payloadJson,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
        createdAt: createdAt,
        sentAt: sentAt ?? this.sentAt,
      );
}

/// Storage behind the outbox; sqflite on the phone, a map in tests.
abstract class OutboxStore {
  Future<OutboxItem?> get(String day);

  /// Inserts or replaces the row for [OutboxItem.day].
  Future<void> put(OutboxItem item);

  /// Unsent items without an error, oldest day first.
  Future<List<OutboxItem>> pending({int? limit});

  /// Unsent items the server rejected, newest day first.
  Future<List<OutboxItem>> failed();
}

class Outbox {
  final OutboxStore store;
  final DateTime Function() _clock;

  Outbox(this.store, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  String _now() => _clock().toUtc().toIso8601String();

  /// Queues [payload] for [day], replacing whatever was stored for that day.
  /// A day that was sent or rejected before is queued again from scratch.
  Future<void> enqueue(String day, Map<String, Object?> payload) async {
    final old = await store.get(day);
    await store.put(OutboxItem(
      day: day,
      payloadJson: jsonEncode(payload),
      createdAt: old != null && old.sentAt == null ? old.createdAt : _now(),
    ));
  }

  Future<List<OutboxItem>> pending({int? limit}) => store.pending(limit: limit);

  Future<int> pendingCount() async => (await store.pending()).length;

  Future<List<OutboxItem>> failed() => store.failed();

  Future<void> markSent(String day) async {
    final item = await store.get(day);
    if (item == null) return;
    await store.put(OutboxItem(
      day: item.day,
      payloadJson: item.payloadJson,
      attempts: item.attempts + 1,
      createdAt: item.createdAt,
      sentAt: _now(),
    ));
  }

  Future<void> markFailed(String day, String error) async {
    final item = await store.get(day);
    if (item == null) return;
    await store.put(item.copyWith(attempts: item.attempts + 1, lastError: error));
  }
}
