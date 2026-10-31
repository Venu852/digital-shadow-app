import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';

import 'drift_contract.dart';

const _min = 60000;

/// An ordinary day: 50 opens, 100 switches, 50 unlocks, 200 screen minutes
/// (10 of them at night), 180 app minutes, on at 07:00 and off at 23:00.
DayRaw raw(
  String day, {
  int opens = 50,
  int switches = 100,
  int wakeups = 60,
  int unlocks = 50,
  int screenMin = 200,
  int nightMin = 10,
  int appMin = 180,
  int? firstOn = 420,
  int? lastOff = 1380,
  bool hasBehavior = true,
}) =>
    DayRaw(
      day: day,
      hasBehavior: hasBehavior,
      opens: opens,
      switches: switches,
      wakeups: wakeups,
      unlocks: unlocks,
      screenMs: screenMin * _min,
      nightScreenMs: nightMin * _min,
      appMs: appMin * _min,
      firstOnMin: firstOn,
      lastOffMin: lastOff,
    );

Duration ist(String _) => const Duration(hours: 5, minutes: 30);

/// [n] ordinary days before [day] plus [today] on [day].
Map<String, DayMetrics> history(String day, DayRaw today,
    {int n = 20, DayRaw Function(String day)? before}) {
  final out = <String, DayMetrics>{};
  for (var i = 1; i <= n; i++) {
    final d = addDays(day, -i);
    out[d] = dayMetrics((before ?? raw)(d), useUnlocks: true);
  }
  out[day] = dayMetrics(today, useUnlocks: true);
  return out;
}

DayDrift score(DayRaw today, {int n = 20, DayRaw Function(String)? before}) =>
    scoreDay(today.day, history(today.day, today, n: n, before: before),
        offsetFor: ist);

// 2026-10-26 is a Monday.
const monday = '2026-10-26';

void main() {
  test('constant history gives levels at 12 and Stable', () {
    final d = score(raw(monday));
    expect(d.reportedLevels.values, everyElement(12));
    expect(d.drift, 12);
    expect(driftBand(d.drift!), DriftBand.stable);
    expect(d.baseline, 'established');
  });

  test('floors stop huge z on a constant history', () {
    // The baseline deviation is 0; the floor max(10% of 100, 5) = 10 keeps
    // one extra switch at z = 0.1.
    expect(score(raw(monday, switches: 101)).levels['switching'], 14);
    expect(score(raw(monday, opens: 51)).levels['session'], 15);
    expect(score(raw(monday, unlocks: 53)).levels['checks'], 25);
    expect(score(raw(monday, screenMin: 210)).levels['screen'], 23);
    expect(score(raw(monday, nightMin: 20)).levels['night'], 34);
    expect(score(raw(monday, firstOn: 450)).levels['timing'], 34);
  });

  test('a switching spike raises that level and the drift', () {
    final d = score(raw(monday, switches: 130));
    expect(d.levels['switching'], 78);
    expect(d.drift, 23);
    expect(d.dominant, 'switching');
    expect(driftBand(d.drift!), DriftBand.early);
  });

  test('shorter sessions raise the session level, longer do not', () {
    // 180 min / 90 opens = 2.0 min vs 3.6 min usual, floor 0.5.
    expect(score(raw(monday, opens: 90)).levels['session'], 82);
    // 300 min / 50 opens = 6.0 min: longer sessions sit below 12.
    expect(score(raw(monday, appMin: 300)).levels['session'], 0);
  });

  test('late-night use rises with late-night minutes', () {
    final l = [10, 20, 30, 40]
        .map((m) => score(raw(monday, nightMin: m)).levels['night']!)
        .toList();
    expect(l, [12, 34, 56, 78]);
  });

  test('timing is two-sided', () {
    expect(score(raw(monday, firstOn: 330)).levels['timing'], 78);
    expect(score(raw(monday, firstOn: 510)).levels['timing'], 78);
    expect(score(raw(monday, lastOff: 1290)).levels['timing'], 78);
    // The larger of the two shifts counts.
    expect(score(raw(monday, firstOn: 450, lastOff: 1440)).levels['timing'],
        56);
  });

  test('fewer than 5 baseline days is calibrating with no payload', () {
    final d = score(raw(monday, switches: 300), n: 4);
    expect(d.drift, isNull);
    expect(d.baseline, 'calibrating');
    expect(d.payload(), isNull);
    expect(d.reportedLevels.values, everyElement(12));
    expect(d.needDays, 1);
    expect(score(raw(monday), n: 2).needDays, 3);
  });

  test('fewer than 4 usable signals is calibrating', () {
    // Old rows without screen time and with few opens: only switching,
    // checks and timing can be scored.
    DayRaw old(String day) => raw(day, opens: 3, screenMin: 0, nightMin: 0);
    final d = score(old(monday), before: old);
    expect(d.levels.values.whereType<int>(), hasLength(3));
    expect(d.drift, isNull);
    expect(d.payload(), isNull);
  });

  test('screen and night are missing when activity has no screen time', () {
    final noScreen = dayMetrics(
        raw(monday, screenMin: 0, nightMin: 0, opens: 10),
        useUnlocks: true);
    expect(noScreen.has('screen'), isFalse);
    expect(noScreen.has('night'), isFalse);
    expect(noScreen.has('switching'), isTrue);

    final appOnly = dayMetrics(
        raw(monday, screenMin: 0, nightMin: 0, opens: 0, appMin: 5),
        useUnlocks: true);
    expect(appOnly.has('screen'), isFalse);

    // A quiet day with no activity at all really had zero screen time.
    final quiet = dayMetrics(
        raw(monday, screenMin: 0, nightMin: 0, opens: 0, appMin: 0),
        useUnlocks: true);
    expect(quiet.values['screen'], 0);
    expect(quiet.values['night'], 0);

    // Such days are left out of the baseline instead of counting as zero.
    final d = score(raw(monday),
        before: (day) => day.compareTo('2026-10-16') < 0
            ? raw(day, screenMin: 0, nightMin: 0)
            : raw(day));
    expect(d.levels['screen'], 12);
  });

  test('session needs 5 opens and checks fall back to wake-ups', () {
    expect(dayMetrics(raw(monday, opens: 4), useUnlocks: true).has('session'),
        isFalse);
    expect(dayMetrics(raw(monday, opens: 5), useUnlocks: true)
        .values['session'], 36);
    expect(dayMetrics(raw(monday), useUnlocks: false).values['checks'], 60);
    expect(dayMetrics(raw(monday), useUnlocks: true).values['checks'], 50);
  });

  test('leave-one-out: the day and later days are not in its baseline', () {
    final h = history(monday, raw(monday, switches: 130), n: 10);
    // With the day itself in the baseline the level would be about 70.
    expect(scoreDay(monday, h, offsetFor: ist).levels['switching'], 78);
    h[addDays(monday, 1)] =
        dayMetrics(raw(addDays(monday, 1), switches: 500), useUnlocks: true);
    expect(scoreDay(monday, h, offsetFor: ist).levels['switching'], 78);
  });

  test('only the previous 28 days form the baseline', () {
    final h = history(monday, raw(monday), n: 28);
    for (var i = 29; i <= 40; i++) {
      final d = addDays(monday, -i);
      h[d] = dayMetrics(raw(d, switches: 1000), useUnlocks: true);
    }
    expect(scoreDay(monday, h, offsetFor: ist).levels['switching'], 12);
  });

  test('weekday days use same-type baseline only with 5 or more', () {
    DayRaw split(String day) =>
        raw(day, switches: isWeekend(day) ? 200 : 100);
    // 20 weekdays and 8 weekend days before Monday: weekdays only.
    expect(score(raw(monday), n: 28, before: split).levels['switching'], 12);
    // Sunday 2026-10-25 against its 8 earlier weekend days.
    expect(
        score(raw('2026-10-25', switches: 200), n: 28, before: split)
            .levels['switching'],
        12);
    // The 6 days before Monday hold 4 weekdays and 2 weekend days, so all
    // 6 are pooled: mean 133.3, sd 47.1.
    expect(score(raw(monday), n: 6, before: split).levels['switching'], 0);
    expect(
        score(raw(monday, switches: 200), n: 6, before: split)
            .levels['switching'],
        43);
  });

  test('confidence formula', () {
    // 10 earlier days plus the day itself.
    expect(score(raw(monday), n: 10).confidence, 84);
    expect(score(raw(monday), n: 4).confidence, 60);
    expect(score(raw(monday), n: 28).confidence, 95);
    // Days without any data do not count.
    final h = history(monday, raw(monday), n: 10)..remove(addDays(monday, -3));
    expect(scoreDay(monday, h, offsetFor: ist).confidence, 80);
  });

  test('band edges', () {
    expect(driftBand(0), DriftBand.stable);
    expect(driftBand(19), DriftBand.stable);
    expect(driftBand(20), DriftBand.early);
    expect(driftBand(44), DriftBand.early);
    expect(driftBand(45), DriftBand.elevated);
    expect(driftBand(69), DriftBand.elevated);
    expect(driftBand(70), DriftBand.high);
    expect(driftBand(100), DriftBand.high);
    expect(DriftBand.values.map((b) => b.label),
        ['Stable', 'Early drift', 'Elevated drift', 'High drift']);
  });

  test('driftWithout puts one signal back at 12', () {
    final all = {for (final k in signalKeys) k: 12}..['switching'] = 78;
    expect(driftOf(all), 23);
    expect(driftWithout(all, 'switching'), 12);
    expect(driftWithout(all, 'night'), 23);

    // Unusable signals stay out of the mean.
    final some = <String, int?>{...all, 'night': null, 'timing': null};
    expect(driftOf(some), 29);
    expect(driftWithout(some, 'switching'), 12);
    expect(driftWithout(some, 'night'), 29);

    final d = score(raw(monday, switches: 130, nightMin: 30));
    expect(d.dominant, 'switching');
    expect(driftWithout(d.levels, d.dominant), 19);
  });

  test('dominant ties go by signal order', () {
    final d = score(raw(monday, switches: 130, nightMin: 40));
    expect(d.levels['switching'], d.levels['night']);
    expect(d.dominant, 'switching');
  });

  test('payload has exactly the allowed keys and ranges', () {
    final p = score(raw(monday, switches: 400, opens: 200)).payload()!;
    expect(p.keys, unorderedEquals(
        ['drift', 'levels', 'confidence', 'baseline', 'tz']));
    expect(p['tz'], '+05:30');
    expect(validateDayPayload(jsonDecode(jsonEncode(p))), isNull);
    expect((p['levels'] as Map).keys, signalKeys);

    // The validator itself rejects what the server rejects.
    expect(validateDayPayload({...p, 'unusual_hours': <int>[]}),
        'Unknown field');
    expect(validateDayPayload({...p, 'drift': 101}), isNotNull);
    expect(validateDayPayload({...p, 'drift': 12.5}), isNotNull);
    expect(
        validateDayPayload({
          ...p,
          'levels': {...p['levels'] as Map, 'extra': 1}
        }),
        isNotNull);
    expect(validateDayPayload({...p, 'tz': '5:30'}), isNotNull);
    expect(validateDayPayload({...p}..remove('confidence')), isNotNull);
  });

  test('the Phase 5 test summary uses the six keys', () {
    // Same values as AccountScreen._sendTestSummary.
    final levels = {
      'switching': 55,
      'session': 40,
      'checks': 35,
      'screen': 30,
      'night': 20,
      'timing': 25,
    };
    expect(driftOf(levels), 34);
    expect(
        validateDayPayload({
          'drift': 34,
          'levels': levels,
          'confidence': 76,
          'baseline': 'established',
          'tz': formatTzOffset(const Duration(hours: -3, minutes: -30)),
        }),
        isNull);
  });

  test('14 synthetic days give six-key levels and valid payloads', () {
    const last = '2026-10-30';
    final rawDays = <DayRaw>[
      for (var i = 0; i < 42; i++)
        raw(addDays(last, -i),
            switches: 90 + (i * 7) % 25,
            opens: 45 + (i * 3) % 11,
            unlocks: 45 + (i * 5) % 13,
            screenMin: 180 + (i * 11) % 50,
            nightMin: (i * 13) % 20,
            firstOn: 400 + (i * 17) % 45,
            lastOff: 1350 + (i * 19) % 60)
    ];
    final out = scoreRecentDays(rawDays, last,
        useUnlocks: true, offsetFor: ist);
    expect(out, hasLength(14));
    expect(out.first.day, last);
    expect(out.last.day, addDays(last, -13));
    for (final d in out) {
      expect(d.established, isTrue, reason: d.day);
      expect(d.levels.keys, signalKeys);
      final p = d.payload()!;
      expect(validateDayPayload(jsonDecode(jsonEncode(p))), isNull,
          reason: d.day);
    }
    // Days after lastDay are ignored.
    final withToday = [...rawDays, raw(addDays(last, 1), switches: 900)];
    expect(
        scoreRecentDays(withToday, last, useUnlocks: true, offsetFor: ist)
            .map((d) => d.drift),
        out.map((d) => d.drift));
  });

  test('formatTzOffset and day helpers', () {
    expect(formatTzOffset(const Duration(hours: 5, minutes: 30)), '+05:30');
    expect(formatTzOffset(const Duration(hours: -4)), '-04:00');
    expect(addDays('2026-03-01', -1), '2026-02-28');
    expect(addDays('2026-12-31', 1), '2027-01-01');
    expect(isWeekend('2026-10-24'), isTrue);
    expect(isWeekend(monday), isFalse);
  });
}
