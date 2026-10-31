import 'package:flutter/material.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/sync/sync_service.dart';
import 'package:test_app/ui/theme.dart';

const Map<String, String> sharingLabels = {
  'nothing': 'Nothing',
  'team_totals': 'Group totals only',
  'my_trend': 'My drift trend',
};

const Map<String, String> sharingHelp = {
  'nothing': 'Nothing leaves this phone.',
  'team_totals': 'Your days count towards your group\'s totals only. '
      'Nobody sees your own trend.',
  'my_trend': 'Your group coordinator can also see your own drift trend.',
};

class SharingState {
  final String level;
  final DateTime? pausedSince;
  final String? levelBeforePause;

  const SharingState(this.level, {this.pausedSince, this.levelBeforePause});

  bool get paused => pausedSince != null;

  /// Whole days since the pause began.
  int pausedDays(DateTime now) {
    final since = pausedSince;
    return since == null ? 0 : now.toUtc().difference(since.toUtc()).inDays;
  }
}

/// Sets, pauses and resumes the sharing level through putSharing. Nothing
/// here runs on a timer: a pause lasts until the person resumes.
class SharingControl {
  static const String pausedSinceKey = 'sharing_paused_since';
  static const String beforePauseKey = 'sharing_level_before_pause';

  final SyncSettings settings;

  /// Sends a level to the server; returns null when the phone is not paired.
  final Future<ApiResult<String>?> Function(String level) send;
  final DateTime Function() _clock;

  SharingControl({
    required this.settings,
    required this.send,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static SharingControl get instance => SharingControl(
        settings: SyncService.instance.settings,
        send: (level) async =>
            (await SyncService.instance.client())?.putSharing(level),
      );

  Future<SharingState> load() async {
    final level = await settings.get('sharing_level') ?? 'nothing';
    final since =
        DateTime.tryParse(await settings.get(pausedSinceKey) ?? '');
    final before = await settings.get(beforePauseKey);
    return SharingState(
      sharingLabels.containsKey(level) ? level : 'nothing',
      pausedSince: since,
      levelBeforePause: sharingLabels.containsKey(before) ? before : null,
    );
  }

  /// Returns null on success, otherwise a message for the person.
  Future<String?> _apply(String level) async {
    // Choosing Nothing stops uploads on this phone before asking the server.
    if (level == 'nothing') await settings.set('sharing_level', 'nothing');
    final r = await send(level);
    if (r == null) return 'This phone is not paired.';
    if (r.ok) {
      await settings.set('sharing_level', r.value!);
      return null;
    }
    if (r.failure == ApiFailure.unauthorized) {
      await settings.set('sync_status', SyncStatus.signedOut);
    }
    return level == 'nothing'
        ? 'Uploads are stopped on this phone, but the server could not be '
            'told: ${r.message}'
        : 'Sharing was not changed: ${r.message}';
  }

  Future<void> _clearPause() =>
      settings.remove(const [pausedSinceKey, beforePauseKey]);

  /// A level the person chose. A successful choice ends any pause.
  Future<String?> setLevel(String level) async {
    final error = await _apply(level);
    if (error == null) await _clearPause();
    return error;
  }

  /// Remembers the current level and sets Nothing. Does nothing when
  /// already paused or already sharing nothing.
  Future<String?> pause() async {
    final s = await load();
    if (s.paused || s.level == 'nothing') return null;
    await settings.set(beforePauseKey, s.level);
    await settings.set(pausedSinceKey, _clock().toUtc().toIso8601String());
    return _apply('nothing');
  }

  /// Restores the level saved by [pause]. The pause stays if the server
  /// does not accept the level.
  Future<String?> resume() async {
    final s = await load();
    if (!s.paused) return null;
    final before = s.levelBeforePause;
    if (before == null) {
      await _clearPause();
      return null;
    }
    final error = await _apply(before);
    if (error == null) await _clearPause();
    return error;
  }
}

class SharingChip extends StatelessWidget {
  final SharingState state;

  const SharingChip(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final label = state.paused
        ? 'Sharing paused'
        : 'Sharing: ${sharingLabels[state.level] ?? 'Nothing'}';
    return Chip(
      avatar: Icon(
        state.paused || state.level == 'nothing'
            ? Icons.cloud_off_outlined
            : Icons.cloud_done_outlined,
        size: 18,
        color: ShadowColors.primary,
      ),
      label: Text(label),
    );
  }
}
