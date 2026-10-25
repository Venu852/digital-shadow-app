import 'package:test_app/data/db.dart';
import 'package:test_app/sync/outbox.dart';
import 'package:test_app/sync/sync_service.dart';

/// Outbox rows in the app's sqflite database.
class DbOutboxStore implements OutboxStore {
  const DbOutboxStore();

  static OutboxItem _item(Map<String, Object?> r) => OutboxItem(
        day: r['day'] as String,
        payloadJson: r['payload_json'] as String,
        attempts: ((r['attempts'] as num?) ?? 0).toInt(),
        lastError: r['last_error'] as String?,
        createdAt: r['created_at'] as String,
        sentAt: r['sent_at'] as String?,
      );

  @override
  Future<OutboxItem?> get(String day) async {
    final r = await ShadowDb.outboxGet(day);
    return r == null ? null : _item(r);
  }

  @override
  Future<void> put(OutboxItem item) => ShadowDb.outboxPut({
        'day': item.day,
        'payload_json': item.payloadJson,
        'attempts': item.attempts,
        'last_error': item.lastError,
        'created_at': item.createdAt,
        'sent_at': item.sentAt,
      });

  @override
  Future<List<OutboxItem>> pending({int? limit}) async =>
      (await ShadowDb.outboxPending(limit)).map(_item).toList();

  @override
  Future<List<OutboxItem>> failed() async =>
      (await ShadowDb.outboxFailed()).map(_item).toList();
}

/// Sync settings in the app's settings table.
class DbSyncSettings implements SyncSettings {
  const DbSyncSettings();

  @override
  Future<String?> get(String key) => ShadowDb.getSetting(key);

  @override
  Future<void> set(String key, String value) => ShadowDb.setSetting(key, value);

  @override
  Future<void> remove(List<String> keys) => ShadowDb.deleteSettings(keys);
}
