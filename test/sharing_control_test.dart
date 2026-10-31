import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/sync/sync_service.dart';
import 'package:test_app/ui/sharing.dart';

class MemorySettings implements SyncSettings {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(List<String> keys) async => keys.forEach(values.remove);
}

void main() {
  late MemorySettings settings;
  late List<String> sent;
  late DateTime now;
  ApiResult<String>? Function(String level) answer =
      (level) => ApiResult.ok(level, 200);
  late SharingControl control;

  setUp(() {
    settings = MemorySettings()..values['sharing_level'] = 'my_trend';
    sent = [];
    now = DateTime.utc(2026, 11, 1, 9);
    answer = (level) => ApiResult.ok(level, 200);
    control = SharingControl(
      settings: settings,
      send: (level) async {
        sent.add(level);
        return answer(level);
      },
      clock: () => now,
    );
  });

  test('pause saves the previous level and sets Nothing', () async {
    expect(await control.pause(), isNull);
    expect(sent, ['nothing']);
    expect(settings.values['sharing_level'], 'nothing');
    expect(settings.values[SharingControl.beforePauseKey], 'my_trend');
    expect(settings.values[SharingControl.pausedSinceKey],
        now.toIso8601String());
    final s = await control.load();
    expect(s.paused, isTrue);
    expect(s.levelBeforePause, 'my_trend');
  });

  test('resume restores the previous level and ends the pause', () async {
    await control.pause();
    expect(await control.resume(), isNull);
    expect(sent, ['nothing', 'my_trend']);
    expect(settings.values['sharing_level'], 'my_trend');
    expect(settings.values.containsKey(SharingControl.pausedSinceKey), isFalse);
    expect(settings.values.containsKey(SharingControl.beforePauseKey), isFalse);
    expect((await control.load()).paused, isFalse);
  });

  test('nothing resumes automatically', () async {
    await control.pause();
    now = now.add(const Duration(days: 60));
    final s = await control.load();
    expect(s.paused, isTrue);
    expect(s.pausedDays(now), 60);
    expect(settings.values['sharing_level'], 'nothing');
    expect(sent, ['nothing']);
  });

  test('pause does nothing when already paused or sharing nothing', () async {
    await control.pause();
    expect(await control.pause(), isNull);
    expect(sent, ['nothing']);
    expect(settings.values[SharingControl.beforePauseKey], 'my_trend');

    settings.values
      ..clear()
      ..['sharing_level'] = 'nothing';
    expect(await control.pause(), isNull);
    expect(sent, ['nothing']);
    expect((await control.load()).paused, isFalse);
  });

  test('a refused resume keeps the pause', () async {
    await control.pause();
    answer = (level) => ApiResult.http(500, 'Server error');
    expect(await control.resume(), 'Sharing was not changed: Server error');
    expect(settings.values['sharing_level'], 'nothing');
    expect((await control.load()).paused, isTrue);
  });

  test('a pause the server cannot hear about still stops uploads', () async {
    answer = (level) => const ApiResult.network('offline');
    final error = await control.pause();
    expect(error, startsWith('Uploads are stopped on this phone'));
    expect(settings.values['sharing_level'], 'nothing');
    expect((await control.load()).paused, isTrue);
  });

  test('choosing a level ends a pause', () async {
    await control.pause();
    expect(await control.setLevel('team_totals'), isNull);
    expect(settings.values['sharing_level'], 'team_totals');
    expect((await control.load()).paused, isFalse);
  });

  test('an unauthorized answer marks the phone signed out', () async {
    answer = (level) => ApiResult.http(401, 'Signed out');
    await control.setLevel('team_totals');
    expect(settings.values['sync_status'], SyncStatus.signedOut);
    expect(settings.values['sharing_level'], 'my_trend');
  });
}
