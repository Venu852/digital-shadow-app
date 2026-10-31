import 'dart:math' as math;

/// The six signals in the server's order (app/rules.py SIGNALS).
const List<String> signalKeys = [
  'switching',
  'session',
  'checks',
  'screen',
  'night',
  'timing',
];

const Map<String, String> signalNames = {
  'switching': 'App switching',
  'session': 'Session length',
  'checks': 'Phone checks',
  'screen': 'Screen time',
  'night': 'Late-night use',
  'timing': 'Routine timing',
};

/// The level a signal sits at on an ordinary day, and for a missing signal.
const int neutralLevel = 12;

const int baselineWindowDays = 28;
const int minBaselineDays = 5;
const int minUsableSignals = 4;

/// "+05:30" style offset, as the server expects in `tz`.
String formatTzOffset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final m = offset.inMinutes.abs();
  return '$sign${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

DateTime _date(String day) => DateTime.utc(
    int.parse(day.substring(0, 4)),
    int.parse(day.substring(5, 7)),
    int.parse(day.substring(8, 10)));

String _key(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// [day] moved by [n] calendar days.
String addDays(String day, int n) {
  final d = _date(day);
  return _key(DateTime.utc(d.year, d.month, d.day + n));
}

bool isWeekend(String day) => _date(day).weekday >= DateTime.saturday;

/// The offset of the phone's local time zone at [day]'s local midnight.
Duration localOffsetAt(String day) {
  final d = _date(day);
  return DateTime(d.year, d.month, d.day).timeZoneOffset;
}

enum DriftBand {
  stable('Stable'),
  early('Early drift'),
  elevated('Elevated drift'),
  high('High drift');

  final String label;
  const DriftBand(this.label);
}

DriftBand driftBand(int drift) {
  if (drift < 20) return DriftBand.stable;
  if (drift < 45) return DriftBand.early;
  if (drift < 70) return DriftBand.elevated;
  return DriftBand.high;
}

/// One local day's totals as stored on the phone.
class DayRaw {
  final String day;

  /// False when the day has no usage_behavior_hourly rows.
  final bool hasBehavior;
  final int opens;
  final int switches;
  final int wakeups;
  final int unlocks;
  final int screenMs;

  /// Screen-on time in hours 0-4 (00:00 to 05:00 local).
  final int nightScreenMs;

  /// Sum of app_usage_hourly for the day.
  final int appMs;
  final int? firstOnMin;
  final int? lastOffMin;

  const DayRaw({
    required this.day,
    this.hasBehavior = true,
    this.opens = 0,
    this.switches = 0,
    this.wakeups = 0,
    this.unlocks = 0,
    this.screenMs = 0,
    this.nightScreenMs = 0,
    this.appMs = 0,
    this.firstOnMin,
    this.lastOffMin,
  });

  bool get hasData =>
      hasBehavior || appMs > 0 || (firstOnMin != null && lastOffMin != null);
}

/// The day's value for each signal; a missing key means the metric could
/// not be computed that day. Timing is held as firstOn/lastOff.
class DayMetrics {
  final String day;
  final Map<String, double> values;
  final int? firstOnMin;
  final int? lastOffMin;

  const DayMetrics(this.day, this.values, {this.firstOnMin, this.lastOffMin});

  bool has(String key) => key == 'timing'
      ? firstOnMin != null && lastOffMin != null
      : values.containsKey(key);
}

/// Turns stored totals into metrics. [useUnlocks] is true when any unlock
/// was ever recorded on this phone; otherwise wake-ups count as checks.
DayMetrics dayMetrics(DayRaw r, {required bool useUnlocks}) {
  final v = <String, double>{};
  final appMin = r.appMs / 60000;
  if (r.hasBehavior) {
    v['switching'] = r.switches.toDouble();
    v['checks'] = (useUnlocks ? r.unlocks : r.wakeups).toDouble();
    if (r.opens >= 5) v['session'] = appMin / r.opens;
  }
  // Rows saved before screen tracking existed have activity but no screen
  // time; those days have no screen or night value rather than zero.
  final noScreenData = r.screenMs == 0 && (r.opens > 0 || appMin > 0);
  if ((r.hasBehavior || appMin > 0) && !noScreenData) {
    v['screen'] = r.screenMs / 60000;
    v['night'] = r.nightScreenMs / 60000;
  }
  return DayMetrics(r.day, v,
      firstOnMin: r.firstOnMin, lastOffMin: r.lastOffMin);
}

/// Mean and floored standard deviation of a baseline.
class Baseline {
  final double mean;
  final double sd;
  final int days;

  const Baseline(this.mean, this.sd, this.days);

  static Baseline? of(List<double> xs, double Function(double mean) floor) {
    if (xs.isEmpty) return null;
    final mean = xs.reduce((a, b) => a + b) / xs.length;
    final variance =
        xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
            xs.length;
    return Baseline(mean, math.max(math.sqrt(variance), floor(mean)), xs.length);
  }

  double z(double x) => (x - mean) / sd;
}

double _floor(String key, double mean) {
  switch (key) {
    case 'switching':
      return math.max(0.1 * mean, 5);
    case 'session':
      return math.max(0.1 * mean, 0.5);
    case 'checks':
      return math.max(0.1 * mean, 3);
    case 'screen':
    case 'night':
      return math.max(0.1 * mean, 10);
    default:
      return 30;
  }
}

int levelForZ(double z) => (neutralLevel + 22 * z).round().clamp(0, 100);

/// Mean of the usable levels (non-null), or null with fewer than
/// [minUsableSignals].
int? driftOf(Map<String, int?> levels) {
  final usable = levels.values.whereType<int>().toList();
  if (usable.length < minUsableSignals) return null;
  return (usable.reduce((a, b) => a + b) / usable.length).round();
}

/// The drift if signal [key] sat at the neutral level 12.
int? driftWithout(Map<String, int?> levels, String key) {
  final copy = Map<String, int?>.of(levels);
  if (copy[key] != null) copy[key] = neutralLevel;
  return driftOf(copy);
}

class DayDrift {
  final String day;

  /// Null when the day is calibrating.
  final int? drift;

  /// All six keys; null means the signal was missing or had too short a
  /// baseline (reported as 12).
  final Map<String, int?> levels;
  final int confidence;
  final String dominant;
  final String tz;

  /// For calibrating days: roughly how many more days of data are needed.
  final int needDays;

  const DayDrift({
    required this.day,
    required this.drift,
    required this.levels,
    required this.confidence,
    required this.dominant,
    required this.tz,
    this.needDays = 0,
  });

  String get baseline => drift == null ? 'calibrating' : 'established';

  bool get established => drift != null;

  /// Levels as uploaded: six ints, missing signals at 12.
  Map<String, int> get reportedLevels =>
      {for (final k in signalKeys) k: levels[k] ?? neutralLevel};

  /// The server's day summary, or null for a calibrating day (never sent).
  Map<String, Object?>? payload() {
    final d = drift;
    if (d == null) return null;
    return {
      'drift': d,
      'levels': reportedLevels,
      'confidence': confidence,
      'baseline': baseline,
      'tz': tz,
    };
  }
}

/// Baseline values of [key] from the days before [day] in the window,
/// using same-type days (weekday or weekend) when there are enough.
List<List<double>> _baselineValues(
    String key, String day, Map<String, DayMetrics> byDay) {
  final weekend = isWeekend(day);
  final same = <DayMetrics>[];
  final all = <DayMetrics>[];
  for (var i = 1; i <= baselineWindowDays; i++) {
    final m = byDay[addDays(day, -i)];
    if (m == null || !m.has(key)) continue;
    all.add(m);
    if (isWeekend(m.day) == weekend) same.add(m);
  }
  final use = same.length >= minBaselineDays ? same : all;
  if (key == 'timing') {
    return [
      [for (final m in use) m.firstOnMin!.toDouble()],
      [for (final m in use) m.lastOffMin!.toDouble()],
    ];
  }
  return [
    [for (final m in use) m.values[key]!]
  ];
}

int? _level(String key, DayMetrics today, Map<String, DayMetrics> byDay) {
  if (!today.has(key)) return null;
  final series = _baselineValues(key, today.day, byDay);
  if (series.first.length < minBaselineDays) return null;
  if (key == 'timing') {
    final first = Baseline.of(series[0], (m) => _floor(key, m))!;
    final last = Baseline.of(series[1], (m) => _floor(key, m))!;
    final z = math.max(first.z(today.firstOnMin!.toDouble()).abs(),
        last.z(today.lastOffMin!.toDouble()).abs());
    return levelForZ(z);
  }
  final b = Baseline.of(series.first, (m) => _floor(key, m))!;
  final x = today.values[key]!;
  // Shorter sessions are the shift that counts; everything else rises.
  return levelForZ(key == 'session' ? -b.z(x) : b.z(x));
}

/// Scores [day] against the person's own earlier days in [history].
DayDrift scoreDay(String day, Map<String, DayMetrics> history,
    {Duration Function(String day) offsetFor = localOffsetAt}) {
  final today = history[day] ?? DayMetrics(day, const {});
  final levels = <String, int?>{
    for (final k in signalKeys) k: _level(k, today, history)
  };
  final drift = driftOf(levels);

  var dataDays = 0;
  for (var i = 0; i < baselineWindowDays; i++) {
    if (history.containsKey(addDays(day, -i))) dataDays++;
  }

  var dominant = signalKeys.first;
  var best = -1;
  for (final k in signalKeys) {
    final l = levels[k] ?? neutralLevel;
    if (l > best) {
      best = l;
      dominant = k;
    }
  }

  var need = 0;
  if (drift == null) {
    final shortBy = [
      for (final k in signalKeys)
        math.max(0, minBaselineDays - _baselineValues(k, day, history).first.length)
    ]..sort();
    need = math.max(1, shortBy[minUsableSignals - 1]);
  }

  return DayDrift(
    day: day,
    drift: drift,
    levels: levels,
    confidence: math.min(95, 40 + 4 * dataDays),
    dominant: dominant,
    tz: formatTzOffset(offsetFor(day)),
    needDays: need,
  );
}

/// Scores the [count] completed days ending at [lastDay], newest first.
/// [raw] should reach back [baselineWindowDays] before the oldest day.
List<DayDrift> scoreRecentDays(List<DayRaw> raw, String lastDay,
    {int count = 14,
    required bool useUnlocks,
    Duration Function(String day) offsetFor = localOffsetAt}) {
  final history = <String, DayMetrics>{
    for (final r in raw)
      if (r.hasData && r.day.compareTo(lastDay) <= 0)
        r.day: dayMetrics(r, useUnlocks: useUnlocks)
  };
  return [
    for (var i = 0; i < count; i++)
      scoreDay(addDays(lastDay, -i), history, offsetFor: offsetFor)
  ];
}
