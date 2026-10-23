import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/service/usage_model.dart';

void main() {
  const today = '2026-10-18';
  final now = DateTime(2026, 10, 18, 15, 30);
  final beh = <Map<String, Object?>>[];
  final fg = <Map<String, Object?>>[];

  void addHour(String day, int h,
      {int unlocks = 3,
        int opens = 4,
        int switches = 2,
        int ms = 600000,
        int apps = 3}) {
    beh.add({
      'day': day,
      'hour': h,
      'opens': opens,
      'switches': switches,
      'wakeups': unlocks + 1,
      'unlocks': unlocks,
    });
    fg.add({'day': day, 'hour': h, 'ms': ms, 'apps': apps});
  }

  void addRegularDay(String day) {
    for (var h = 8; h <= 22; h++) {
      addHour(day, h);
    }
  }

  UsageInsights run() => analyzeUsage(
      behaviorRows: beh, fgRows: fg, now: now, todayKey: today);

  setUp(() {
    beh.clear();
    fg.clear();
  });

  test('not ready with fewer than 3 earlier days', () {
    addRegularDay('2026-10-16');
    addRegularDay('2026-10-17');
    addHour(today, 9);
    final r = run();
    expect(r.ready, isFalse);
    expect(r.flagsToday, isEmpty);
    expect(r.forecasts, isEmpty);
  });

  test('a night spike is flagged and normal hours are not', () {
    for (final d in ['2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17']) {
      addRegularDay(d);
    }
    for (var h = 8; h <= 14; h++) {
      addHour(today, h);
    }
    addHour(today, 3,
        unlocks: 15, opens: 6, switches: 4, ms: 900000, apps: 4);
    final r = run();
    expect(r.ready, isTrue);
    expect(r.flagsToday.any((s) => s.sample.hour == 3), isTrue);
    expect(r.flagsToday.any((s) => s.sample.hour == 9), isFalse);
  });

  test('forecast is what happened so far plus the usual rest of the day', () {
    for (final d in ['2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17']) {
      addRegularDay(d);
    }
    for (var h = 8; h <= 14; h++) {
      addHour(today, h);
    }
    addHour(today, 3,
        unlocks: 15, opens: 6, switches: 4, ms: 900000, apps: 4);
    final f = run().forecasts['pickups']!;
    expect(f.actualSoFar, closeTo(36.0, 1e-9));
    expect(f.expectedRest, closeTo(24.0, 1e-9));
    expect(f.total, closeTo(60.0, 1e-9));
    expect(f.usualTotal, closeTo(45.0, 1e-9));
  });

  test('falls back to screen wake-ups when unlocks are not reported', () {
    beh.add({
      'day': '2026-10-17',
      'hour': 10,
      'opens': 2,
      'switches': 1,
      'wakeups': 5,
      'unlocks': 0,
    });
    expect(run().unlocksReported, isFalse);
  });
}