import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/service/usage_model.dart';

void main() {
  const today = '2026-10-18';
  final now = DateTime(2026, 10, 18, 15, 30);

  Map<String, Object?> beh(String day, int h, {int notifications = 3}) => {
    'day': day,
    'hour': h,
    'opens': 4,
    'switches': 2,
    'wakeups': 4,
    'unlocks': 3,
    'notifications': notifications,
    'screen_ms': 0,
  };

  Map<String, Object?> fg(String day, int h) =>
      {'day': day, 'hour': h, 'ms': 600000, 'apps': 3};

  test('a burst of notifications is flagged', () {
    final b = <Map<String, Object?>>[];
    final f = <Map<String, Object?>>[];
    for (final d in ['2026-10-14', '2026-10-15', '2026-10-16', '2026-10-17']) {
      for (var h = 8; h <= 22; h++) {
        b.add(beh(d, h));
        f.add(fg(d, h));
      }
    }
    for (var h = 8; h <= 14; h++) {
      b.add(beh(today, h, notifications: h == 10 ? 40 : 3));
      f.add(fg(today, h));
    }
    final r =
    analyzeUsage(behaviorRows: b, fgRows: f, now: now, todayKey: today);
    expect(r.ready, isTrue);
    expect(
        r.flagsToday
            .any((s) => s.sample.hour == 10 && s.topFeature == 'notifs'),
        isTrue);
    expect(r.flagsToday.any((s) => s.sample.hour == 9), isFalse);
  });
}