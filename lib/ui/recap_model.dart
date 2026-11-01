import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/today_model.dart';

/// Scored days in a recap week.
const int recapDays = 7;

/// Check-ins needed before their average is shown.
const int recapMinCheckins = 3;

class WeeklyRecap {
  final int average;

  /// The average of the 7 scored days before, or null in the first week.
  final int? previousAverage;
  final String dominant;
  final int dominantDays;
  final String steadiestDay;
  final int steadiestDrift;
  final double? checkinAverage;
  final int checkinCount;

  const WeeklyRecap({
    required this.average,
    required this.previousAverage,
    required this.dominant,
    required this.dominantDays,
    required this.steadiestDay,
    required this.steadiestDrift,
    required this.checkinAverage,
    required this.checkinCount,
  });

  String get averageText {
    final p = previousAverage;
    if (p == null) {
      return 'This was your first full week: your average drift was $average.';
    }
    if (p == average) {
      return 'Your average drift this week was $average, the same as the '
          'week before.';
    }
    return 'Your average drift this week was $average, '
        '${average > p ? 'up' : 'down'} from $p the week before.';
  }

  String get dominantText =>
      '${signalNames[dominant]} moved most on $dominantDays of $recapDays '
      'days.';

  String get steadiestText =>
      'Your steadiest day was ${formatDay(steadiestDay)}, with a drift of '
      '$steadiestDrift.';

  String? get checkinText => checkinAverage == null
      ? null
      : 'Your check-in average was ${checkinAverage!.toStringAsFixed(1)} '
            'from $checkinCount check-ins.';

  List<String> get sentences => [
    averageText,
    dominantText,
    steadiestText,
    ?checkinText,
  ];
}

int _mean(Iterable<int> xs) => (xs.reduce((a, b) => a + b) / xs.length).round();

/// The recap of the newest [recapDays] scored days in [days] (any order),
/// or null with fewer. [checkins] maps a day to its 1-5 score.
WeeklyRecap? buildRecap(List<DayDrift> days, Map<String, int> checkins) {
  final scored = days.where((d) => d.established).toList()
    ..sort((a, b) => b.day.compareTo(a.day));
  if (scored.length < recapDays) return null;
  final week = scored.take(recapDays).toList();
  final previous = scored.skip(recapDays).take(recapDays).toList();

  final counts = {for (final k in signalKeys) k: 0};
  for (final d in week) {
    if (counts.containsKey(d.dominant)) {
      counts[d.dominant] = counts[d.dominant]! + 1;
    }
  }
  var dominant = signalKeys.first;
  for (final k in signalKeys) {
    if (counts[k]! > counts[dominant]!) dominant = k;
  }

  // Oldest first, so ties go to the earlier day.
  var steadiest = week.last;
  for (final d in week.reversed) {
    if (d.drift! < steadiest.drift!) steadiest = d;
  }

  final scores = [
    for (final d in week)
      if (checkins[d.day] != null) checkins[d.day]!,
  ];
  return WeeklyRecap(
    average: _mean(week.map((d) => d.drift!)),
    previousAverage: previous.length < recapDays
        ? null
        : _mean(previous.map((d) => d.drift!)),
    dominant: dominant,
    dominantDays: counts[dominant]!,
    steadiestDay: steadiest.day,
    steadiestDrift: steadiest.drift!,
    checkinAverage: scores.length < recapMinCheckins
        ? null
        : scores.reduce((a, b) => a + b) / scores.length,
    checkinCount: scores.length,
  );
}
