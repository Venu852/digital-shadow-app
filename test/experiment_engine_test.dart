import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/suggest/experiment_engine.dart';
import 'package:test_app/suggest/suggestion_builder.dart';

const String start = '2026-11-01';

const Suggestion switching = Suggestion(
  key: 'sig:switching',
  kind: SuggestionKind.signal,
  signal: 'switching',
  text: 'Try checking messages at set times instead of switching all day.',
);

final DateTime now = DateTime.utc(2026, 11, 9, 8);

/// 60 on each of the 7 days before [start] (and 99 the day before those),
/// [after] on each day from [start] for [afterDays] days.
Map<String, double> values({double after = 40, int afterDays = 7}) => {
  addDays(start, -8): 99,
  for (var i = 1; i <= 7; i++) addDays(start, -i): 60,
  for (var i = 0; i < afterDays; i++) addDays(start, i): after,
};

void main() {
  final e = startExperiment(switching, start);

  test('Try for a week runs from today to six days later', () {
    expect(e.startDay, start);
    expect(e.endDay, '2026-11-07');
    expect(e.status, ExperimentStatus.running);
    expect(e.signal, 'switching');
    expect(e.key, 'sig:switching');
  });

  test('shows Day N of 7', () {
    expect(experimentDayNumber(e, start), 1);
    expect(experimentDayNumber(e, addDays(start, 3)), 4);
    expect(experimentDayNumber(e, addDays(start, 6)), 7);
    expect(experimentDayNumber(e, addDays(start, 20)), 7);
  });

  test('before is the 7 days before the start; after only completed days', () {
    final w = experimentWindows(e, values(), addDays(start, 3));
    expect(w.before, List.filled(7, 60.0));
    expect(w.beforeAvg, 60);
    // Today (start + 3) is not complete yet.
    expect(w.after, hasLength(3));
  });

  test('the after window ends at 7 days', () {
    final v = {
      ...values(),
      for (var i = 7; i < 14; i++) addDays(start, i): 0.0,
    };
    final w = experimentWindows(e, v, addDays(start, 30));
    expect(w.after, List.filled(7, 40.0));
    expect(w.afterAvg, 40);
  });

  test('nothing is decided until the 7 days are over', () {
    expect(evaluateExperiment(e, values(), e.endDay, now), isNull);
    final done = evaluateExperiment(e, values(), addDays(e.endDay, 1), now)!;
    expect(done.status, ExperimentStatus.done);
    expect(done.beforeAvg, 60);
    expect(done.afterAvg, 40);
    expect(done.finishedAt, now.toIso8601String());
  });

  test('a result needs at least 5 completed days with data', () {
    final four = evaluateExperiment(
      e,
      values(afterDays: 4),
      addDays(start, 7),
      now,
    )!;
    expect(four.status, ExperimentStatus.done);
    expect(four.beforeAvg, isNull);
    expect(four.afterAvg, isNull);
    expect(
      experimentResultText(four, switching.text),
      'Over the week you tried \'${switching.text}\', fewer than 5 days had '
      'data, so there is nothing to compare. An observation, not proof.',
    );
    expect(experimentDirection(four), isNull);

    final five = evaluateExperiment(
      e,
      values(afterDays: 5),
      addDays(start, 7),
      now,
    )!;
    expect(five.afterAvg, 40);
  });

  test('the result wording, where lower is better', () {
    final done = evaluateExperiment(e, values(), addDays(start, 7), now)!;
    expect(
      experimentResultText(done, switching.text),
      'Over the week you tried \'${switching.text}\', your app switching '
      'level went from 60 to 40. An observation, not proof.',
    );
    expect(
      experimentDirection(done),
      'Lower than before, the direction this aimed for.',
    );

    final higher = evaluateExperiment(
      e,
      values(after: 75),
      addDays(start, 7),
      now,
    )!;
    expect(experimentDirection(higher), 'Higher than before.');
    final same = evaluateExperiment(
      e,
      values(after: 60.2),
      addDays(start, 7),
      now,
    )!;
    expect(experimentDirection(same), 'About the same as before.');
  });

  test('no earlier days still gives an observation', () {
    final v = {for (var i = 0; i < 7; i++) addDays(start, i): 40.0};
    final done = evaluateExperiment(e, v, addDays(start, 7), now)!;
    expect(done.beforeAvg, isNull);
    expect(
      experimentResultText(done, switching.text),
      'Over the week you tried \'${switching.text}\', your app switching '
      'level was 40. There were no earlier days to compare with. An '
      'observation, not proof.',
    );
  });

  test('a cancelled experiment is never evaluated', () {
    final c = cancelExperiment(e, now);
    expect(c.status, ExperimentStatus.cancelled);
    expect(c.finishedAt, now.toIso8601String());
    expect(evaluateExperiment(c, values(), addDays(start, 30), now), isNull);
  });

  test('a row round-trips', () {
    final done = evaluateExperiment(
      e,
      values(),
      addDays(start, 7),
      now,
    )!.copyWith(id: 3);
    final back = Experiment.fromRow({...done.toRow(), 'id': 3});
    expect(back.id, 3);
    expect(back.key, done.key);
    expect(back.status, done.status);
    expect(back.beforeAvg, 60);
    expect(back.afterAvg, 40);
  });

  group('measured values', () {
    test('signal levels from established days only', () {
      final v = measuredValues(
        'sig:switching',
        driftDays: [
          DayDrift(
            day: start,
            drift: 30,
            levels: {for (final k in signalKeys) k: 30},
            confidence: 80,
            dominant: 'switching',
            tz: '+00:00',
          ),
          DayDrift(
            day: addDays(start, 1),
            drift: null,
            levels: {for (final k in signalKeys) k: null},
            confidence: 40,
            dominant: 'switching',
            tz: '+00:00',
          ),
        ],
      );
      expect(v, {start: 30.0});
    });

    test('late-night minutes for the night nudge', () {
      final v = measuredValues(
        nightNudgeKey,
        phoneDays: [
          const PhoneDay(day: start, nightMinutes: 42),
          PhoneDay(day: addDays(start, 1), hasScreen: false),
        ],
      );
      expect(v, {start: 42.0});
    });

    test('days over the limit for a limit nudge, shown as a share', () {
      const limit = DailyLimit('limit_min_social', 'Social media', 60);
      final key = limitNudgeKey(limit.key);
      final phone = [
        for (var i = -7; i < 7; i++)
          PhoneDay(
            day: addDays(start, i),
            limitMinutes: {limit.key: i < 0 && i.isOdd ? 90 : 30},
          ),
      ];
      final v = measuredValues(key, phoneDays: phone, limits: [limit]);
      expect(v[addDays(start, -2)], 0);
      expect(v[addDays(start, -1)], 1);
      expect(measuredValues(key, phoneDays: phone), isEmpty);

      final ex = Experiment(
        key: key,
        startDay: start,
        endDay: addDays(start, 6),
      );
      final done = evaluateExperiment(ex, v, addDays(start, 7), now)!;
      expect(
        experimentResultText(done, 'A quiet hour', limitName: 'Social media'),
        'Over the week you tried \'A quiet hour\', your days over the Social '
        'media limit went from 57% of days to 0% of days. An observation, '
        'not proof.',
      );
    });
  });
}
