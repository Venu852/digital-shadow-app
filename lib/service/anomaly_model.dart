import 'dart:convert';
import 'dart:math';

class FeatureStat {
  int n;
  double mean;
  double m2;
  FeatureStat([this.n = 0, this.mean = 0, this.m2 = 0]);

  void add(double v) {
    n++;
    final d = v - mean;
    mean += d / n;
    m2 += d * (v - mean);
  }

  double get std => n < 2 ? 0 : sqrt(m2 / (n - 1));

  Map<String, dynamic> toJson() => {'n': n, 'mean': mean, 'm2': m2};

  factory FeatureStat.fromJson(Map<String, dynamic> j) => FeatureStat(
    (j['n'] as num).toInt(),
    (j['mean'] as num).toDouble(),
    (j['m2'] as num).toDouble(),
  );
}

class ScoreResult {
  final double? score;
  final bool isAnomaly;
  final bool calibrating;
  final int windowsSeen;
  const ScoreResult({
    required this.score,
    required this.isAnomaly,
    required this.calibrating,
    required this.windowsSeen,
  });
}

class AnomalyModel {
  static const int calibrationWindows = 20;
  static const double anomalyThreshold = 0.5;
  static const double zClip = 6.0;
  static const Map<String, double> minStd = {
    'accel_mag_mean': 0.05,
    'accel_mag_std': 0.01,
    'accel_mag_max': 0.1,
    'gyro_mag_mean': 0.01,
    'gyro_mag_std': 0.01,
  };

  final Map<String, FeatureStat> _stats = {};
  int windowsSeen = 0;

  Map<String, double> _extract(Map<String, dynamic> f) {
    final out = <String, double>{};
    for (final k in minStd.keys) {
      final v = f[k];
      if (v is num && v.isFinite) out[k] = v.toDouble();
    }
    return out;
  }

  void _learn(Map<String, double> values) {
    values.forEach((k, v) => _stats.putIfAbsent(k, () => FeatureStat()).add(v));
  }

  ScoreResult process(Map<String, dynamic> features) {
    final values = _extract(features);
    final calibrating = windowsSeen < calibrationWindows;

    if (values.isEmpty) {
      return ScoreResult(
          score: null,
          isAnomaly: false,
          calibrating: calibrating,
          windowsSeen: windowsSeen);
    }

    if (calibrating) {
      _learn(values);
      windowsSeen++;
      return ScoreResult(
          score: null,
          isAnomaly: false,
          calibrating: true,
          windowsSeen: windowsSeen);
    }

    final zs = <double>[];
    values.forEach((k, v) {
      final s = _stats[k];
      if (s == null || s.n < 2) return;
      final denom = max(s.std, minStd[k]!);
      zs.add((v - s.mean).abs() / denom);
    });

    windowsSeen++;
    if (zs.isEmpty) {
      return ScoreResult(
          score: null,
          isAnomaly: false,
          calibrating: false,
          windowsSeen: windowsSeen);
    }

    zs.sort((a, b) => b.compareTo(a));
    final top = zs.take(3).toList();
    final avg = top.reduce((a, b) => a + b) / top.length;
    final score = min(avg, zClip) / zClip;
    final anomaly = score > anomalyThreshold;
    if (!anomaly) _learn(values);

    return ScoreResult(
        score: score,
        isAnomaly: anomaly,
        calibrating: false,
        windowsSeen: windowsSeen);
  }

  Map<String, dynamic> toJson() => {
    'windows': windowsSeen,
    'stats': _stats.map((k, v) => MapEntry(k, v.toJson())),
  };

  String toJsonString() => jsonEncode(toJson());

  static AnomalyModel fromJsonString(String s) {
    final m = AnomalyModel();
    try {
      final j = jsonDecode(s) as Map<String, dynamic>;
      m.windowsSeen = (j['windows'] as num?)?.toInt() ?? 0;
      final stats = (j['stats'] as Map?) ?? {};
      stats.forEach((k, v) {
        m._stats['$k'] =
            FeatureStat.fromJson(Map<String, dynamic>.from(v as Map));
      });
    } catch (_) {
      return AnomalyModel();
    }
    return m;
  }
}