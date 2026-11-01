import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/suggest/suggestion_builder.dart';

/// An experiment lasts this many days, starting on the day it is begun.
const int experimentDays = 7;

/// Completed days with data needed after the start for a result.
const int minAfterDays = 5;

const String observationNote = 'An observation, not proof.';

/// Values of experiments.status.
class ExperimentStatus {
  static const String running = 'running';
  static const String done = 'done';
  static const String cancelled = 'cancelled';
}

class Experiment {
  final int? id;
  final String key;
  final String? signal;
  final String startDay;
  final String endDay;
  final String status;
  final double? beforeAvg;
  final double? afterAvg;
  final String? finishedAt;

  const Experiment({
    this.id,
    required this.key,
    this.signal,
    required this.startDay,
    required this.endDay,
    this.status = ExperimentStatus.running,
    this.beforeAvg,
    this.afterAvg,
    this.finishedAt,
  });

  bool get running => status == ExperimentStatus.running;

  Experiment copyWith({
    int? id,
    String? status,
    double? beforeAvg,
    double? afterAvg,
    String? finishedAt,
  }) => Experiment(
    id: id ?? this.id,
    key: key,
    signal: signal,
    startDay: startDay,
    endDay: endDay,
    status: status ?? this.status,
    beforeAvg: beforeAvg ?? this.beforeAvg,
    afterAvg: afterAvg ?? this.afterAvg,
    finishedAt: finishedAt ?? this.finishedAt,
  );

  Map<String, Object?> toRow() => {
    'key': key,
    'signal': signal,
    'start_day': startDay,
    'end_day': endDay,
    'status': status,
    'before_avg': beforeAvg,
    'after_avg': afterAvg,
    'finished_at': finishedAt,
  };

  static Experiment fromRow(Map<String, Object?> r) => Experiment(
    id: (r['id'] as num?)?.toInt(),
    key: '${r['key']}',
    signal: r['signal'] as String?,
    startDay: '${r['start_day']}',
    endDay: '${r['end_day']}',
    status: '${r['status']}',
    beforeAvg: (r['before_avg'] as num?)?.toDouble(),
    afterAvg: (r['after_avg'] as num?)?.toDouble(),
    finishedAt: r['finished_at'] as String?,
  );
}

/// "Try for a week": from [today] to six days later.
Experiment startExperiment(Suggestion s, String today) => Experiment(
  key: s.key,
  signal: s.signal,
  startDay: today,
  endDay: addDays(today, experimentDays - 1),
);

Experiment cancelExperiment(Experiment e, DateTime now) => e.copyWith(
  status: ExperimentStatus.cancelled,
  finishedAt: now.toUtc().toIso8601String(),
);

/// 1 on the start day, up to 7.
int experimentDayNumber(Experiment e, String today) {
  var n = 1;
  while (n < experimentDays && addDays(e.startDay, n).compareTo(today) <= 0) {
    n++;
  }
  return n;
}

/// The measured value per completed day for [key]; lower is better for
/// every kind. Days without data are left out.
Map<String, double> measuredValues(
  String key, {
  List<DayDrift> driftDays = const [],
  List<PhoneDay> phoneDays = const [],
  List<DailyLimit> limits = const [],
}) {
  if (key.startsWith('sig:')) {
    final signal = key.substring(4);
    return {
      for (final d in driftDays)
        if (d.established && d.levels[signal] != null)
          d.day: d.levels[signal]!.toDouble(),
    };
  }
  if (key == nightNudgeKey) {
    return {
      for (final p in phoneDays)
        if (p.hasScreen) p.day: p.nightMinutes,
    };
  }
  if (key.startsWith(limitNudgePrefix)) {
    // A day counts 1 when over the limit, so the average is the share of
    // days over it. A removed limit has nothing to measure.
    final limitKey = key.substring(limitNudgePrefix.length);
    final limit = limits.where((l) => l.key == limitKey).firstOrNull;
    if (limit == null) return const {};
    return {
      for (final p in phoneDays)
        if (p.hasUsage)
          p.day: (p.limitMinutes[limitKey] ?? 0) > limit.minutes ? 1 : 0,
    };
  }
  return const {};
}

double? _mean(List<double> xs) =>
    xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;

class ExperimentWindows {
  /// Values of the 7 days before the start that have data.
  final List<double> before;

  /// Values of the completed days from the start day, up to 7.
  final List<double> after;

  const ExperimentWindows(this.before, this.after);

  double? get beforeAvg => _mean(before);

  double? get afterAvg => _mean(after);
}

/// Only days before [today] count, since today is not complete.
ExperimentWindows experimentWindows(
  Experiment e,
  Map<String, double> values,
  String today,
) {
  final before = <double>[];
  for (var i = experimentDays; i >= 1; i--) {
    final v = values[addDays(e.startDay, -i)];
    if (v != null) before.add(v);
  }
  final after = <double>[];
  for (var i = 0; i < experimentDays; i++) {
    final day = addDays(e.startDay, i);
    if (day.compareTo(today) >= 0) break;
    final v = values[day];
    if (v != null) after.add(v);
  }
  return ExperimentWindows(before, after);
}

/// The finished experiment once its 7 days are over, else null. The
/// averages are left empty when fewer than [minAfterDays] days had data.
Experiment? evaluateExperiment(
  Experiment e,
  Map<String, double> values,
  String today,
  DateTime now,
) {
  if (!e.running || today.compareTo(e.endDay) <= 0) return null;
  final w = experimentWindows(e, values, today);
  final enough = w.after.length >= minAfterDays;
  return Experiment(
    id: e.id,
    key: e.key,
    signal: e.signal,
    startDay: e.startDay,
    endDay: e.endDay,
    status: ExperimentStatus.done,
    beforeAvg: enough ? w.beforeAvg : null,
    afterAvg: enough ? w.afterAvg : null,
    finishedAt: now.toUtc().toIso8601String(),
  );
}

/// What was measured, for "your <label> went from".
String measuredLabel(String key, {String? limitName}) {
  if (key.startsWith('sig:')) {
    return '${signalNames[key.substring(4)]!.toLowerCase()} level';
  }
  if (key == nightNudgeKey) return 'late-night minutes';
  return 'days over the ${limitName ?? 'daily'} limit';
}

String _value(String key, double v) => key.startsWith(limitNudgePrefix)
    ? '${(v * 100).round()}% of days'
    : '${v.round()}';

/// The result card's text, or a note when there was too little data.
String experimentResultText(Experiment e, String text, {String? limitName}) {
  final before = e.beforeAvg;
  final after = e.afterAvg;
  if (after == null) {
    return 'Over the week you tried \'$text\', fewer than $minAfterDays days '
        'had data, so there is nothing to compare. $observationNote';
  }
  final label = measuredLabel(e.key, limitName: limitName);
  if (before == null) {
    return 'Over the week you tried \'$text\', your $label was '
        '${_value(e.key, after)}. There were no earlier days to compare '
        'with. $observationNote';
  }
  return 'Over the week you tried \'$text\', your $label went from '
      '${_value(e.key, before)} to ${_value(e.key, after)}. $observationNote';
}

/// Lower is better for every measured value.
String? experimentDirection(Experiment e) {
  final before = e.beforeAvg;
  final after = e.afterAvg;
  if (before == null || after == null) return null;
  final b = _value(e.key, before);
  final a = _value(e.key, after);
  if (a == b) return 'About the same as before.';
  return after < before
      ? 'Lower than before, the direction this aimed for.'
      : 'Higher than before.';
}
