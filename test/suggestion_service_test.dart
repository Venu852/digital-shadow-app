import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_repository.dart';
import 'package:test_app/suggest/experiment_engine.dart';
import 'package:test_app/suggest/suggest_store.dart';
import 'package:test_app/suggest/suggestion_builder.dart';
import 'package:test_app/suggest/suggestion_service.dart';

/// Drift days in memory: [levels] on every listed day.
class FakeDriftRepository implements DriftRepository {
  final Map<String, Map<String, int>> levels = {};

  @override
  bool get simulated => false;

  @override
  Future<List<DayDrift>> driftDays(String fromDay, String toDay) async {
    final days =
        levels.keys
            .where((d) => d.compareTo(fromDay) >= 0 && d.compareTo(toDay) <= 0)
            .toList()
          ..sort((a, b) => b.compareTo(a));
    return [
      for (final d in days)
        DayDrift(
          day: d,
          drift: driftOf(levels[d]!),
          levels: levels[d]!,
          confidence: 80,
          dominant: 'switching',
          tz: '+00:00',
        ),
    ];
  }

  @override
  Future<int> dataDays(String fromDay, String toDay) async =>
      (await driftDays(fromDay, toDay)).length;

  @override
  Future<Map<String, int>> checkins(String fromDay, String toDay) async =>
      const {};

  @override
  Future<List<DailyLimit>> limits() async => const [];

  @override
  Future<List<PhoneDay>> phoneDays(
    String fromDay,
    String toDay,
    List<DailyLimit> limits,
  ) async => const [];
}

Map<String, int> lv({int switching = 12, int night = 12}) => {
  'switching': switching,
  'session': 12,
  'checks': 30,
  'screen': 12,
  'night': night,
  'timing': 12,
};

void main() {
  late FakeDriftRepository repo;
  late MemorySuggestStore store;
  late DateTime now;
  late SuggestionService service;

  String today() => '2026-11-${now.day.toString().padLeft(2, '0')}';

  setUp(() {
    SuggestionService.resetOpenCheck();
    repo = FakeDriftRepository();
    store = MemorySuggestStore();
    now = DateTime(2026, 11, 8, 9);
    service = SuggestionService(
      repository: repo,
      store: store,
      clock: () => now,
    );
    // 7 days of switching at 70 before 2026-11-08: drift 26.
    for (var i = 1; i <= 7; i++) {
      repo.levels[addDays('2026-11-08', -i)] = lv(switching: 70, night: 30);
    }
  });

  test('offers the two highest signals', () async {
    final v = await service.load();
    expect(v.offered.map((s) => s.key), ['sig:switching', 'sig:checks']);
    expect(v.running, isEmpty);
  });

  test('a personal context lowers the drift below the threshold', () async {
    final v = await service.load(context: 'Exams');
    expect(v.offered, isEmpty);
  });

  test('Try for a week starts one experiment and hides the offer', () async {
    final s = (await service.load()).offered.first;
    await service.tryForWeek(s);
    await service.tryForWeek(s);
    expect(store.experimentRows, hasLength(1));
    expect(store.stateRows['sig:switching']!.status, SuggestionStatus.trying);

    final v = await service.load();
    // Only the two highest signals are offered, so none takes its place.
    expect(v.offered.map((x) => x.key), ['sig:checks']);
    expect(v.running.single.dayNumber, 1);
    expect(v.running.single.text, personalSuggestionTexts['switching']);
  });

  test('Not now returns after 14 days, Not useful after 60', () async {
    final offered = (await service.load()).offered;
    await service.notNow(offered[0]);
    await service.notUseful(offered[1]);
    expect(store.stateRows['sig:switching']!.until, '2026-11-22');
    expect(store.stateRows['sig:checks']!.until, '2027-01-07');
    expect((await service.load()).offered, isEmpty);

    now = DateTime(2026, 11, 22, 9);
    for (var i = 1; i <= 14; i++) {
      repo.levels[addDays(today(), -i)] = lv(switching: 70, night: 30);
    }
    expect((await service.load()).offered.map((s) => s.key), ['sig:switching']);
  });

  test('Stop experiment cancels it and rests the suggestion', () async {
    final s = (await service.load()).offered.first;
    await service.tryForWeek(s);
    final running = (await service.load()).running.single;
    await service.stop(running.experiment);
    expect(store.experimentRows.single.status, ExperimentStatus.cancelled);
    expect(store.stateRows['sig:switching']!.status, SuggestionStatus.done);
    final v = await service.load();
    expect(v.running, isEmpty);
    expect(v.results, isEmpty);
    expect(v.offered.map((x) => x.key), isNot(contains('sig:switching')));
  });

  test('a finished week is evaluated once per app open', () async {
    final s = (await service.load()).offered.first;
    await service.tryForWeek(s);
    // The week of 2026-11-08 to 11-14, with switching down to 40.
    for (var i = 0; i < 7; i++) {
      repo.levels[addDays('2026-11-08', i)] = lv(switching: 40, night: 30);
    }
    now = DateTime(2026, 11, 15, 9);

    // Already checked since this "open": still running.
    final same = await service.load();
    expect(same.running.single.dayNumber, 7);
    expect(store.experimentRows.single.status, ExperimentStatus.running);

    SuggestionService.resetOpenCheck();
    final v = await service.load();
    expect(v.running, isEmpty);
    final e = store.experimentRows.single;
    expect(e.status, ExperimentStatus.done);
    expect(e.beforeAvg, 70);
    expect(e.afterAvg, 40);
    expect(
      v.results.single.resultText,
      'Over the week you tried \'${s.text}\', your app switching level '
      'went from 70 to 40. An observation, not proof.',
    );
    expect(store.stateRows['sig:switching']!.status, SuggestionStatus.done);
  });
}
