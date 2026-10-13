import 'dart:math';

class _Stat {
  int n = 0;
  double _mean = 0;
  double _m2 = 0;
  double _max = double.negativeInfinity;

  void add(double v) {
    n++;
    final d = v - _mean;
    _mean += d / n;
    _m2 += d * (v - _mean);
    if (v > _max) _max = v;
  }

  double? get mean => n == 0 ? null : _mean;
  double? get std => n < 2 ? null : sqrt(_m2 / (n - 1));
  double? get max => n == 0 ? null : _max;
}

class WindowAggregator {
  DateTime? _start;
  _Stat _accel = _Stat();
  _Stat _gyro = _Stat();

  DateTime? get windowStart => _start;
  int get accelCount => _accel.n;
  int get gyroCount => _gyro.n;

  void start(DateTime t) {
    _start = t;
    _accel = _Stat();
    _gyro = _Stat();
  }

  void addAccel(double x, double y, double z) {
    if (_start == null) return;
    _accel.add(sqrt(x * x + y * y + z * z));
  }

  void addGyro(double x, double y, double z) {
    if (_start == null) return;
    _gyro.add(sqrt(x * x + y * y + z * z));
  }

  Map<String, dynamic> close(
      DateTime now, {
        int? batteryStart,
        int? batteryEnd,
        bool? charging,
        String? networkType,
      }) {
    final summary = <String, dynamic>{
      'window_start_ts': _start?.toIso8601String(),
      'window_end_ts': now.toIso8601String(),
      'accel_mag_mean': _accel.mean,
      'accel_mag_std': _accel.std,
      'accel_mag_max': _accel.max,
      'gyro_mag_mean': _gyro.mean,
      'gyro_mag_std': _gyro.std,
      'screen_on_fraction': null,
      'battery_delta': (batteryStart != null && batteryEnd != null)
          ? batteryEnd - batteryStart
          : null,
      'charging': charging,
      'network_type': networkType,
      'sample_count_accel': _accel.n,
      'sample_count_gyro': _gyro.n,
      'no_data': _accel.n == 0 && _gyro.n == 0,
    };
    start(now);
    return summary;
  }
}