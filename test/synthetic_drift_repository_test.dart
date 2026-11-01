import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/demo/synthetic_drift_repository.dart';
import 'package:test_app/drift/drift_engine.dart';

const String today = '2026-11-01';
const String yesterday = '2026-10-31';

void main() {
  const repo = SyntheticDriftRepository(today: today);

  Future<List<DayDrift>> story(SyntheticDriftRepository r) =>
      r.driftDays(addDays(r.today, -60), addDays(r.today, -1));

  test('21 days ending yesterday, newest first', () async {
    final days = await story(repo);
    expect(days, hasLength(syntheticDays));
    expect(days.first.day, yesterday);
    expect(days.last.day, addDays(yesterday, -20));
    expect(days.every((d) => d.established), isTrue);
    expect(repo.simulated, isTrue);
  });

  test('is deterministic', () async {
    final a = await story(repo);
    final b = await story(const SyntheticDriftRepository(today: today));
    expect([for (final d in a) d.drift], [for (final d in b) d.drift]);
    expect([for (final d in a) d.levels], [for (final d in b) d.levels]);

    // Another day gives the same story, shifted.
    final c = await story(const SyntheticDriftRepository(today: '2027-03-15'));
    expect([for (final d in c) d.drift], [for (final d in a) d.drift]);
    expect(c.first.day, '2027-03-14');
  });

  test('drift is the rounded mean of the six levels', () async {
    for (final d in await story(repo)) {
      final levels = d.reportedLevels;
      expect(levels.keys, signalKeys);
      for (final v in levels.values) {
        expect(v, inInclusiveRange(0, 100));
      }
      final mean = levels.values.reduce((a, b) => a + b) / signalKeys.length;
      expect(d.drift, mean.round());
      expect(d.drift, driftOf(d.levels));
    }
  });

  test(
    '14 stable days, then a rise to about 52 led by switching and night',
    () async {
      final oldestFirst = (await story(repo)).reversed.toList();
      for (final d in oldestFirst.take(14)) {
        expect(d.drift, inInclusiveRange(8, 14));
        expect(driftBand(d.drift!), DriftBand.stable);
      }
      final rise = oldestFirst.skip(14).map((d) => d.drift!).toList();
      for (var i = 1; i < rise.length; i++) {
        expect(rise[i], greaterThan(rise[i - 1]));
      }
      final lastDay = oldestFirst.last;
      expect(lastDay.drift, 52);
      expect(lastDay.dominant, 'switching');
      final ranked = signalKeys.toList()
        ..sort((a, b) => lastDay.levels[b]!.compareTo(lastDay.levels[a]!));
      expect(ranked.take(2), ['switching', 'night']);
    },
  );

  test('ranges, check-ins and phone days stay inside the story', () async {
    final week = await repo.driftDays(addDays(yesterday, -6), yesterday);
    expect(week, hasLength(7));
    expect(await repo.dataDays(addDays(yesterday, -27), yesterday), 21);
    expect(await repo.driftDays(today, today), isEmpty);

    final checkins = await repo.checkins(addDays(yesterday, -6), yesterday);
    expect(checkins, hasLength(7));
    expect(checkins.values.every((v) => v >= 1 && v <= 5), isTrue);

    expect(await repo.limits(), isEmpty);
    final phone = await repo.phoneDays(addDays(yesterday, -6), yesterday, []);
    expect(phone.where((p) => p.nightMinutes > 30), hasLength(4));
  });
}
