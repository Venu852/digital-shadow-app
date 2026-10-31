import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/service/screen_state.dart';

void main() {
  const h = 3600000;

  test('hourlyScreenMs splits an interval across hours', () {
    final r = hourlyScreenMs([
      [30 * 60000, 90 * 60000]
    ], 0);
    expect(r[0], 30 * 60000);
    expect(r[1], 30 * 60000);
    expect(r.sublist(2).every((v) => v == 0), isTrue);
  });

  test('hourlyScreenMs clips to the start of the day', () {
    final r = hourlyScreenMs([
      [-h, h ~/ 2]
    ], 0);
    expect(r[0], h ~/ 2);
  });

  test('screenFraction full, half and none', () {
    final iv = [
      [0, 30000]
    ];
    expect(screenFraction(iv, 0, 30000), closeTo(1.0, 1e-9));
    expect(screenFraction(iv, 15000, 45000), closeTo(0.5, 1e-9));
    expect(screenFraction(iv, 40000, 70000), closeTo(0.0, 1e-9));
  });

  group('dayRhythm', () {
    const m = 60000;

    test('first on at or after 05:00 and last off', () {
      final r = dayRhythm([
        [60 * m, 90 * m], // 01:00-01:30, before 05:00
        [7 * 60 * m, 8 * 60 * m],
        [22 * 60 * m, 23 * 60 * m + 15 * m],
      ], 0);
      expect(r, (firstOnMin: 420, lastOffMin: 1395));
    });

    test('a night session spanning 05:00 counts from 05:00', () {
      final r = dayRhythm([
        [4 * 60 * m, 5 * 60 * m + 20 * m],
        [9 * 60 * m, 10 * 60 * m],
      ], 0);
      expect(r, (firstOnMin: 300, lastOffMin: 600));
    });

    test('nothing after 05:00 skips the day', () {
      expect(dayRhythm([
        [60 * m, 5 * 60 * m],
      ], 0), isNull);
      expect(dayRhythm([], 0), isNull);
    });

    test('the end is capped at 1440', () {
      final start = 1000 * h;
      final r = dayRhythm([
        [start + 23 * h, start + 25 * h],
      ], start);
      expect(r, (firstOnMin: 1380, lastOffMin: 1440));
    });
  });
}
