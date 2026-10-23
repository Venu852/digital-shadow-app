import 'dart:math';

const List<String> kFeatures = [
  'pickups',
  'opens',
  'switches',
  'apps',
  'fgMin',
  'screenMin',
  'notifs'
];

/// Smallest deviation unit per feature, so a perfectly regular baseline
/// (std = 0) does not turn a tiny change into a huge score.
const Map<String, double> kMinStd = {
  'pickups': 1.0,
  'opens': 1.0,
  'switches': 1.0,
  'apps': 1.0,
  'fgMin': 3.0,
  'screenMin': 3.0,
  'notifs': 2.0,
};

const int kMinBaselineDays = 3;
const int kMinBucketSamples = 12;
const double kFlagThreshold = 0.5;
const double kZClip = 6.0;

/// 0 = night (12am-6am), 1 = morning, 2 = afternoon, 3 = evening.
int bucketOf(int hour) => hour ~/ 6;

class HourSample {
  final String day; // yyyy-MM-dd
  final int hour; // 0..23
  final Map<String, double> f;
  const HourSample(this.day, this.hour, this.f);
}

class HourScore {
  final HourSample sample;
  final double score; // 0..1
  final bool flagged;
  final String topFeature;
  final double topZ; // signed
  final double expected; // baseline mean of topFeature
  const HourScore({
    required this.sample,
    required this.score,
    required this.flagged,
    required this.topFeature,
    required this.topZ,
    required this.expected,
  });
}

class Forecast {
  final double actualSoFar;
  final double expectedRest;
  final double usualTotal;
  const Forecast(this.actualSoFar, this.expectedRest, this.usualTotal);
  double get total => actualSoFar + expectedRest;
}

class UsageInsights {
  final bool ready;
  final int baselineDays;
  final int dataDays;
  final bool unlocksReported;
  final List<HourScore> flagsToday;
  final List<HourScore> flagsWeek;
  final Map<String, Forecast> forecasts;
  const UsageInsights({
    required this.ready,
    required this.baselineDays,
    required this.dataDays,
    required this.unlocksReported,
    required this.flagsToday,
    required this.flagsWeek,
    required this.forecasts,
  });
}

class _Stat {
  int n = 0;
  double mean = 0;
  double m2 = 0;

  void add(double v) {
    n++;
    final d = v - mean;
    mean += d / n;
    m2 += d * (v - mean);
  }

  double get std => n < 2 ? 0.0 : sqrt(m2 / (n - 1));
}

class Baseline {
  final Map<int, Map<String, _Stat>> _b = {};
  final Set<String> days = {};

  void add(HourSample s) {
    days.add(s.day);
    final m = _b.putIfAbsent(bucketOf(s.hour), () => <String, _Stat>{});
    for (final k in kFeatures) {
      m.putIfAbsent(k, () => _Stat()).add(s.f[k] ?? 0.0);
    }
  }

  double? mean(int bucket, String feature) => _b[bucket]?[feature]?.mean;

  HourScore? score(HourSample s) {
    final b = _b[bucketOf(s.hour)];
    if (b == null) return null;
    final n = b['pickups']?.n ?? 0;
    if (n < kMinBucketSamples) return null;
    final zs = <String, double>{};
    for (final k in kFeatures) {
      final st = b[k];
      if (st == null) continue;
      final denom = max(st.std, kMinStd[k]!);
      zs[k] = ((s.f[k] ?? 0.0) - st.mean) / denom;
    }
    if (zs.isEmpty) return null;
    final sorted = zs.entries.toList()
      ..sort((a, c) => c.value.abs().compareTo(a.value.abs()));
    final top = sorted.take(2).toList();
    final avg =
        top.map((e) => e.value.abs()).reduce((a, c) => a + c) / top.length;
    final score = min(avg, kZClip) / kZClip;
    final lead = sorted.first;
    return HourScore(
      sample: s,
      score: score,
      flagged: score > kFlagThreshold,
      topFeature: lead.key,
      topZ: lead.value,
      expected: b[lead.key]!.mean,
    );
  }
}

UsageInsights analyzeUsage({
  required List<Map<String, Object?>> behaviorRows,
  required List<Map<String, Object?>> fgRows,
  required DateTime now,
  required String todayKey,
}) {
  double num0(Object? v) => v is num ? v.toDouble() : 0.0;
  Map<String, double> zero() => {
    'pickups': 0.0,
    'opens': 0.0,
    'switches': 0.0,
    'apps': 0.0,
    'fgMin': 0.0,
    'screenMin': 0.0,
    'notifs': 0.0,
  };

  var totalUnlocks = 0.0;
  for (final r in behaviorRows) {
    totalUnlocks += num0(r['unlocks']);
  }
  final useUnlocks = totalUnlocks > 0;

  final cells = <String, Map<String, double>>{};
  final days = <String>{};
  Map<String, double> cell(String day, int hour) {
    days.add(day);
    return cells.putIfAbsent('$day|$hour', zero);
  }

  for (final r in behaviorRows) {
    final h = num0(r['hour']).toInt();
    if (h < 0 || h > 23) continue;
    final c = cell('${r['day']}', h);
    c['pickups'] = useUnlocks ? num0(r['unlocks']) : num0(r['wakeups']);
    c['opens'] = num0(r['opens']);
    c['switches'] = num0(r['switches']);
    c['screenMin'] = num0(r['screen_ms']) / 60000.0;
    c['notifs'] = num0(r['notifications']);
  }
  for (final r in fgRows) {
    final h = num0(r['hour']).toInt();
    if (h < 0 || h > 23) continue;
    final c = cell('${r['day']}', h);
    c['fgMin'] = num0(r['ms']) / 60000.0;
    c['apps'] = num0(r['apps']);
  }

  // A day counts as complete when it has activity in at least 6 hours.
  final active = <String, int>{};
  cells.forEach((key, vals) {
    final day = key.substring(0, key.indexOf('|'));
    if (vals.values.any((v) => v > 0)) active[day] = (active[day] ?? 0) + 1;
  });
  final completeDays =
  days.where((d) => d != todayKey && (active[d] ?? 0) >= 6).toSet();

  // One sample per hour; today only up to the current hour.
  final samples = <HourSample>[];
  for (final day in days) {
    final maxH = day == todayKey ? now.hour : 23;
    for (var h = 0; h <= maxH; h++) {
      samples.add(HourSample(day, h, cells['$day|$h'] ?? zero()));
    }
  }

  Baseline baselineFor(String? excludeDay) {
    final b = Baseline();
    for (final s in samples) {
      if (!completeDays.contains(s.day)) continue; // also drops today
      if (s.day == excludeDay) continue;
      b.add(s);
    }
    return b;
  }

  final baseToday = baselineFor(null);
  final ready = baseToday.days.length >= kMinBaselineDays;

  final todays = samples.where((s) => s.day == todayKey).toList();
  final flagsToday = <HourScore>[];
  final flagsWeek = <HourScore>[];
  final forecasts = <String, Forecast>{};

  if (ready) {
    for (final s in todays) {
      if (s.hour >= now.hour) continue; // only completed hours
      final sc = baseToday.score(s);
      if (sc != null && sc.flagged) flagsToday.add(sc);
    }
    flagsToday.sort((a, b) => b.score.compareTo(a.score));
    flagsWeek.addAll(flagsToday);

    for (final day in completeDays) {
      final b = baselineFor(day);
      if (b.days.length < kMinBaselineDays) continue;
      for (final s in samples.where((s) => s.day == day)) {
        final sc = b.score(s);
        if (sc != null && sc.flagged) flagsWeek.add(sc);
      }
    }
    flagsWeek.sort((a, b) => b.score.compareTo(a.score));
    if (flagsWeek.length > 12) flagsWeek.removeRange(12, flagsWeek.length);

    final cur = now.hour;
    for (final f in const ['pickups', 'opens', 'fgMin', 'screenMin', 'notifs']) {
      var actual = 0.0;
      for (final s in todays) {
        if (s.hour <= cur) actual += s.f[f] ?? 0.0;
      }
      var rest = 0.0;
      var usual = 0.0;
      for (var h = 0; h < 24; h++) {
        final mean = baseToday.mean(bucketOf(h), f) ?? 0.0;
        usual += mean;
        if (h == cur) {
          final so = cells['$todayKey|$h']?[f] ?? 0.0;
          rest += max(0.0, mean - so);
        } else if (h > cur) {
          rest += mean;
        }
      }
      forecasts[f] = Forecast(actual, rest, usual);
    }
  }

  return UsageInsights(
    ready: ready,
    baselineDays: baseToday.days.length,
    dataDays: days.length,
    unlocksReported: useUnlocks,
    flagsToday: flagsToday,
    flagsWeek: flagsWeek,
    forecasts: forecasts,
  );
}