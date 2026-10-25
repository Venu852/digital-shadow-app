import 'package:flutter/foundation.dart';
import 'package:test_app/sync/db_stores.dart';
import 'package:test_app/sync/outbox.dart';
import 'package:test_app/sync/server_client.dart';

/// Key/value storage for the sync settings (server_url, device_token, ...).
abstract class SyncSettings {
  Future<String?> get(String key);

  Future<void> set(String key, String value);

  Future<void> remove(List<String> keys);
}

/// Values stored in the sync_status setting.
class SyncStatus {
  static const String ok = 'ok';
  static const String someFailed = 'some_failed';
  static const String offline = 'offline';
  static const String signedOut = 'signed_out';
  static const String sharingOff = 'sharing_off';
  static const String rateLimited = 'rate_limited';
  static const String serverError = 'server_error';

  /// Plain words for the account screen.
  static String describe(String? status) {
    switch (status) {
      case ok:
        return 'Up to date';
      case someFailed:
        return 'Some days were not accepted by the server';
      case offline:
        return 'Could not reach the server. Will try again later.';
      case signedOut:
        return 'This phone was signed out. Pair it again to keep sharing.';
      case sharingOff:
        return 'The server says sharing is off. Nothing was uploaded.';
      case rateLimited:
        return 'The server is busy. Will try again later.';
      case serverError:
        return 'The server had a problem. Will try again later.';
      default:
        return 'Not synced yet';
    }
  }
}

/// Why run() stopped.
enum SyncState {
  notPaired,
  signedOut,
  sharingOff,
  throttled,
  busy,
  done,
  stopped,
}

class SyncResult {
  final SyncState state;
  final int sent;
  final int failed;

  /// The status written to settings, when the run talked to the server.
  final String? status;
  final String? message;

  const SyncResult(this.state,
      {this.sent = 0, this.failed = 0, this.status, this.message});
}

/// Uploads queued daily summaries, oldest first.
class SyncService {
  static const int maxPerRun = 20;
  static const Duration minInterval = Duration(seconds: 60);
  static const Set<String> sharingLevels = {'team_totals', 'my_trend'};

  final Outbox outbox;
  final SyncSettings settings;
  final ServerClient Function(String baseUrl, String token) _clientFor;
  final DateTime Function() _clock;
  DateTime? _lastRun;
  bool _busy = false;

  SyncService({
    required this.outbox,
    required this.settings,
    ServerClient Function(String baseUrl, String token)? clientFor,
    DateTime Function()? clock,
    bool allowCleartext = false,
  })  : _clientFor = clientFor ??
      ((url, token) =>
          ServerClient(url, token: token, allowCleartext: allowCleartext)),
        _clock = clock ?? DateTime.now;

  static SyncService? _instance;

  /// The app-wide service over the sqflite database.
  static SyncService get instance => _instance ??= SyncService(
    outbox: Outbox(const DbOutboxStore()),
    settings: const DbSyncSettings(),
    allowCleartext: kDebugMode,
  );

  /// A client for the paired server, or null when not paired.
  Future<ServerClient?> client() async {
    final url = await settings.get('server_url') ?? '';
    final token = await settings.get('device_token') ?? '';
    if (url.isEmpty || token.isEmpty) return null;
    return _clientFor(url, token);
  }

  Future<bool> isPaired() async =>
      (await settings.get('device_token') ?? '').isNotEmpty;

  /// Stores a new pairing. The token is kept only in the settings table.
  Future<void> savePairing({
    required String serverUrl,
    required String deviceId,
    required String deviceToken,
    required String username,
  }) async {
    await settings.set('server_url', serverUrl);
    await settings.set('device_id', deviceId);
    await settings.set('device_token', deviceToken);
    await settings.set('paired_username', username);
    await settings.remove(['last_sync_at', 'sync_status']);
  }

  /// Forgets the pairing but keeps the server address and the outbox.
  Future<void> forgetPairing() => settings.remove([
    'device_id',
    'device_token',
    'paired_username',
    'sharing_level',
    'last_sync_at',
    'sync_status',
  ]);

  /// Sends up to [maxPerRun] pending days. Runs at most once per
  /// [minInterval] unless [force] is set (a button the person pressed).
  Future<SyncResult> run({bool force = false}) async {
    if (_busy) return const SyncResult(SyncState.busy);
    final client = await this.client();
    if (client == null) return const SyncResult(SyncState.notPaired);
    if (await settings.get('sync_status') == SyncStatus.signedOut) {
      return const SyncResult(SyncState.signedOut);
    }
    if (!sharingLevels.contains(await settings.get('sharing_level'))) {
      return const SyncResult(SyncState.sharingOff);
    }
    final now = _clock();
    final last = _lastRun;
    if (!force && last != null && now.difference(last) < minInterval) {
      return const SyncResult(SyncState.throttled);
    }
    _lastRun = now;
    _busy = true;
    try {
      return await _send(client, now);
    } finally {
      _busy = false;
    }
  }

  Future<SyncResult> _send(ServerClient client, DateTime now) async {
    var sent = 0;
    var failed = 0;
    for (final item in await outbox.pending(limit: maxPerRun)) {
      final Map<String, Object?> payload;
      try {
        payload = item.payload;
      } catch (_) {
        await outbox.markFailed(item.day, 'Stored summary is damaged');
        failed++;
        continue;
      }
      final r = await client.putDay(item.day, payload);
      if (r.ok) {
        await outbox.markSent(item.day);
        sent++;
        continue;
      }
      final String status;
      switch (r.failure) {
        case ApiFailure.invalid:
        case ApiFailure.tooLarge:
          await outbox.markFailed(item.day, r.message ?? 'Rejected');
          failed++;
          continue;
        case ApiFailure.unauthorized:
          status = SyncStatus.signedOut;
        case ApiFailure.sharingOff:
          status = SyncStatus.sharingOff;
        case ApiFailure.network:
          status = SyncStatus.offline;
        case ApiFailure.rateLimited:
          status = SyncStatus.rateLimited;
        default:
          status = SyncStatus.serverError;
      }
      if (sent > 0) await _setLastSync(now);
      await settings.set('sync_status', status);
      return SyncResult(SyncState.stopped,
          sent: sent, failed: failed, status: status, message: r.message);
    }
    final status = failed > 0 ? SyncStatus.someFailed : SyncStatus.ok;
    await _setLastSync(now);
    await settings.set('sync_status', status);
    return SyncResult(SyncState.done,
        sent: sent, failed: failed, status: status);
  }

  Future<void> _setLastSync(DateTime now) =>
      settings.set('last_sync_at', now.toUtc().toIso8601String());
}
