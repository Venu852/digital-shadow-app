import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/why_screen.dart';

DayDrift day(Map<String, int?> levels) => DayDrift(
      day: '2026-10-31',
      drift: driftOf(levels),
      levels: levels,
      confidence: 80,
      dominant: 'switching',
      tz: '+00:00',
    );

void main() {
  test('shares are ranked by level and rounded from level / sum', () {
    final s = signalShares(const {
      'switching': 60,
      'session': 20,
      'checks': 40,
      'screen': 30,
      'night': 10,
      'timing': 40,
    });
    // Sum 200. Ties keep the signal order (checks before timing).
    expect(s.map((x) => x.key),
        ['switching', 'checks', 'timing', 'screen', 'session', 'night']);
    expect(s.map((x) => x.percent), [30, 20, 20, 15, 10, 5]);
  });

  test('all 12s give an even split', () {
    final s = signalShares({for (final k in signalKeys) k: 12});
    expect(s.map((x) => x.percent).toSet(), {17});
    expect(s.map((x) => x.key), signalKeys);
  });

  test('missing signals count as 12', () {
    final s = signalShares(const {
      'switching': 48,
      'session': null,
      'checks': 12,
      'screen': 12,
      'night': null,
      'timing': 12,
    });
    expect(s.first.key, 'switching');
    expect(s.first.percent, 44); // 48 / 108
    expect(s.firstWhere((x) => x.key == 'night').level, 12);
  });

  test('all zeros give an even split', () {
    final s = signalShares({for (final k in signalKeys) k: 0});
    expect(s.map((x) => x.percent).toSet(), {17});
  });

  test('the counterfactual uses the largest signal and driftWithout', () {
    final d = day(const {
      'switching': 72,
      'session': 12,
      'checks': 24,
      'screen': 12,
      'night': 12,
      'timing': 12,
    });
    // Without switching: (12 + 12 + 24 + 12 + 12 + 12) / 6 = 14.
    expect(counterfactualText(d), 'Without app switching your drift would be 14');
  });

  test('no counterfactual while calibrating', () {
    final d = DayDrift(
      day: '2026-10-31',
      drift: null,
      levels: {for (final k in signalKeys) k: null},
      confidence: 40,
      dominant: 'switching',
      tz: '+00:00',
      needDays: 3,
    );
    expect(counterfactualText(d), isNull);
  });
}
