import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/service/anomaly_model.dart';

Map<String, dynamic> win(double accelMean, {double wobble = 0}) => {
  'accel_mag_mean': accelMean + wobble,
  'accel_mag_std': 0.004 + wobble.abs() * 0.1,
  'accel_mag_max': accelMean + 0.02 + wobble,
  'gyro_mag_mean': 0.0005,
  'gyro_mag_std': 0.0002,
};

AnomalyModel calibrated() {
  final m = AnomalyModel();
  for (var i = 0; i < AnomalyModel.calibrationWindows; i++) {
    m.process(win(9.62, wobble: i.isEven ? 0.01 : -0.01));
  }
  return m;
}

void main() {
  test('calibration windows have no score', () {
    final m = AnomalyModel();
    for (var i = 0; i < AnomalyModel.calibrationWindows; i++) {
      final r = m.process(win(9.62, wobble: i.isEven ? 0.01 : -0.01));
      expect(r.score, isNull);
      expect(r.calibrating, isTrue);
    }
    expect(m.windowsSeen, AnomalyModel.calibrationWindows);
  });

  test('normal window scores low after calibration', () {
    final m = calibrated();
    final r = m.process(win(9.63));
    expect(r.calibrating, isFalse);
    expect(r.score, isNotNull);
    expect(r.score!, lessThan(0.5));
    expect(r.isAnomaly, isFalse);
  });

  test('spike scores high and is flagged', () {
    final m = calibrated();
    final r = m.process({
      'accel_mag_mean': 12.0,
      'accel_mag_std': 2.0,
      'accel_mag_max': 20.0,
      'gyro_mag_mean': 1.5,
      'gyro_mag_std': 1.0,
    });
    expect(r.score!, greaterThan(0.5));
    expect(r.isAnomaly, isTrue);
  });

  test('windows without data are skipped', () {
    final m = AnomalyModel();
    final r = m.process({'accel_mag_mean': null, 'no_data': true});
    expect(r.score, isNull);
    expect(m.windowsSeen, 0);
  });

  test('json round trip keeps the baseline', () {
    final m = calibrated();
    final copy = AnomalyModel.fromJsonString(m.toJsonString());
    expect(copy.windowsSeen, m.windowsSeen);
    final a = m.process(win(9.63));
    final b = copy.process(win(9.63));
    expect(b.score, closeTo(a.score!, 1e-9));
  });

  test('corrupt json gives a fresh model', () {
    final m = AnomalyModel.fromJsonString('not json');
    expect(m.windowsSeen, 0);
  });
}