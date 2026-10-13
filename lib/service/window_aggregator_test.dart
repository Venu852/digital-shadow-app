import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/service/window_aggregator.dart';

void main() {
  final t0 = DateTime(2026, 1, 1);
  final t1 = DateTime(2026, 1, 1, 0, 0, 30);

  test('accel magnitude mean, std and max', () {
    final a = WindowAggregator()..start(t0);
    a.addAccel(1, 0, 0);
    a.addAccel(3, 0, 0);
    a.addAccel(5, 0, 0);
    final s = a.close(t1);
    expect(s['accel_mag_mean'], closeTo(3.0, 1e-9));
    expect(s['accel_mag_std'], closeTo(2.0, 1e-9));
    expect(s['accel_mag_max'], closeTo(5.0, 1e-9));
    expect(s['sample_count_accel'], 3);
  });

  test('gyro magnitude mean', () {
    final a = WindowAggregator()..start(t0);
    a.addGyro(0, 3, 4);
    a.addGyro(0, 0, 0);
    final s = a.close(t1);
    expect(s['gyro_mag_mean'], closeTo(2.5, 1e-9));
    expect(s['sample_count_gyro'], 2);
  });

  test('empty window gives nulls and no_data', () {
    final a = WindowAggregator()..start(t0);
    final s = a.close(t1);
    expect(s['accel_mag_mean'], isNull);
    expect(s['gyro_mag_mean'], isNull);
    expect(s['sample_count_accel'], 0);
    expect(s['no_data'], isTrue);
  });

  test('close resets for the next window', () {
    final a = WindowAggregator()..start(t0);
    a.addAccel(1, 0, 0);
    a.addAccel(1, 0, 0);
    a.close(t1);
    a.addAccel(2, 0, 0);
    final s = a.close(DateTime(2026, 1, 1, 0, 1));
    expect(s['sample_count_accel'], 1);
    expect(s['accel_mag_mean'], closeTo(2.0, 1e-9));
  });

  test('battery delta', () {
    final a = WindowAggregator()..start(t0);
    final s = a.close(t1, batteryStart: 80, batteryEnd: 79);
    expect(s['battery_delta'], -1);
  });
}