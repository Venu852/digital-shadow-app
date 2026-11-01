import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/recap_model.dart';

const String last = '2026-10-31';

DayDrift dd(int ago, int? drift, {String dominant = 'switching'}) => DayDrift(
  day: addDays(last, -ago),
  drift: drift,
  levels: {for (final k in signalKeys) k: drift},
  confidence: 80,
  dominant: dominant,
  tz: '+00:00',
);

void main() {
  test('needs 7 scored days', () {
    final six = [for (var i = 0; i < 6; i++) dd(i, 20)];
    expect(buildRecap(six, const {}), isNull);
    // A calibrating day does not count.
    expect(buildRecap([...six, dd(6, null)], const {}), isNull);
    expect(buildRecap([...six, dd(6, 20)], const {}), isNotNull);
  });

  test('the first full week has nothing to compare with', () {
    final r = buildRecap([
      for (var i = 0; i < 9; i++) dd(i, 10 + i),
    ], const {})!;
    // The newest 7: 10..16.
    expect(r.average, 13);
    expect(r.previousAverage, isNull);
    expect(
      r.averageText,
      'This was your first full week: your average drift was 13.',
    );
  });

  test('compares with the 7 scored days before', () {
    final days = [
      for (var i = 0; i < 7; i++) dd(i, 30),
      for (var i = 7; i < 14; i++) dd(i, 12),
    ];
    final r = buildRecap(days.reversed.toList(), const {})!;
    expect(r.average, 30);
    expect(r.previousAverage, 12);
    expect(
      r.averageText,
      'Your average drift this week was 30, up from 12 the week before.',
    );

    final down = buildRecap([
      for (var i = 0; i < 7; i++) dd(i, 12),
      for (var i = 7; i < 14; i++) dd(i, 30),
    ], const {})!;
    expect(
      down.averageText,
      'Your average drift this week was 12, down from 30 the week before.',
    );
  });

  test('counts the dominant signal, ties in signal order', () {
    final r = buildRecap([
      for (var i = 0; i < 3; i++) dd(i, 20, dominant: 'night'),
      for (var i = 3; i < 6; i++) dd(i, 20, dominant: 'checks'),
      dd(6, 20, dominant: 'timing'),
    ], const {})!;
    expect(r.dominant, 'checks');
    expect(r.dominantDays, 3);
    expect(r.dominantText, 'Phone checks moved most on 3 of 7 days.');

    final clear = buildRecap([
      for (var i = 0; i < 4; i++) dd(i, 20, dominant: 'night'),
      for (var i = 4; i < 7; i++) dd(i, 20, dominant: 'switching'),
    ], const {})!;
    expect(clear.dominant, 'night');
    expect(clear.dominantDays, 4);
  });

  test('the steadiest day is the lowest drift, earlier day on a tie', () {
    final r = buildRecap([
      dd(0, 30),
      dd(1, 9),
      dd(2, 25),
      dd(3, 9),
      dd(4, 40),
      dd(5, 18),
      dd(6, 22),
    ], const {})!;
    expect(r.steadiestDay, '2026-10-28');
    expect(r.steadiestDrift, 9);
    expect(
      r.steadiestText,
      'Your steadiest day was Wed 28 Oct, with a drift of 9.',
    );
  });

  test('the check-in average needs at least 3 check-ins in the week', () {
    final week = [for (var i = 0; i < 7; i++) dd(i, 20)];
    final two = buildRecap(week, {last: 4, addDays(last, -1): 3})!;
    expect(two.checkinAverage, isNull);
    expect(two.checkinText, isNull);
    expect(two.sentences, hasLength(3));

    final three = buildRecap(week, {
      last: 4,
      addDays(last, -1): 3,
      addDays(last, -2): 3,
      // Outside the week: ignored.
      addDays(last, -9): 1,
    })!;
    expect(three.checkinCount, 3);
    expect(
      three.checkinText,
      'Your check-in average was 3.3 from 3 check-ins.',
    );
    expect(three.sentences, hasLength(4));
  });

  test('the wording has no alarm words', () {
    final r = buildRecap(
      [
        for (var i = 0; i < 7; i++) dd(i, 80),
        for (var i = 7; i < 14; i++) dd(i, 10),
      ],
      {for (var i = 0; i < 7; i++) addDays(last, -i): 1},
    )!;
    for (final s in r.sentences) {
      for (final w in ['warning', 'alert', 'danger', 'risk', 'bad']) {
        expect(s.toLowerCase(), isNot(contains(w)));
      }
    }
  });
}
