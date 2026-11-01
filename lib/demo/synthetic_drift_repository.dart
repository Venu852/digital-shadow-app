import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_repository.dart';
import 'package:test_app/suggest/suggestion_builder.dart';

/// Days in the demo story, ending yesterday.
const int syntheticDays = 21;

const List<int> _stableDrifts = [
  10,
  12,
  9,
  11,
  13,
  8,
  12,
  10,
  14,
  11,
  9,
  12,
  10,
  13,
];
const List<int> _riseDrifts = [17, 23, 29, 35, 41, 47, 52];

/// Sums to zero, so the levels' mean is exactly the day's drift.
const List<int> _stableOffsets = [3, -2, 1, -3, 2, -1];

/// How the rise is shared out; switching and night lead.
const Map<String, double> _riseWeights = {
  'switching': 2.2,
  'session': 0.6,
  'checks': 1.0,
  'screen': 0.8,
  'night': 1.8,
  'timing': 0.6,
};

const List<double> _riseNightMinutes = [12, 20, 28, 34, 40, 46, 52];
const List<int> _riseCheckins = [4, 4, 3, 3, 3, 2, 2];

/// The six levels of story day [i] (0 = oldest), always summing to six
/// times that day's drift.
Map<String, int> syntheticLevels(int i) {
  if (i < _stableDrifts.length) {
    final d = _stableDrifts[i];
    return {
      for (var k = 0; k < signalKeys.length; k++)
        signalKeys[k]: d + _stableOffsets[(k + i) % _stableOffsets.length],
    };
  }
  final d = _riseDrifts[i - _stableDrifts.length];
  final extra = 6 * (d - neutralLevel);
  final total = _riseWeights.values.reduce((a, b) => a + b);
  final levels = {
    for (final k in signalKeys)
      k: neutralLevel + (extra * _riseWeights[k]! / total).floor(),
  };
  final sum = levels.values.reduce((a, b) => a + b);
  levels['switching'] = levels['switching']! + 6 * d - sum;
  return levels;
}

/// A deterministic 21-day story: 14 stable days with drift 8 to 14, then
/// a rise to 52 led by app switching and late-night use. Nothing here is
/// read from or written to the database.
class SyntheticDriftRepository implements DriftRepository {
  /// The story's last day is the day before [today].
  final String today;

  const SyntheticDriftRepository({required this.today});

  String get firstDay => addDays(today, -syntheticDays);

  Iterable<(int, String)> _story(String fromDay, String toDay) sync* {
    for (var i = 0; i < syntheticDays; i++) {
      final day = addDays(firstDay, i);
      if (day.compareTo(fromDay) >= 0 && day.compareTo(toDay) <= 0) {
        yield (i, day);
      }
    }
  }

  DayDrift dayAt(int i) {
    final levels = syntheticLevels(i);
    var dominant = signalKeys.first;
    for (final k in signalKeys) {
      if (levels[k]! > levels[dominant]!) dominant = k;
    }
    return DayDrift(
      day: addDays(firstDay, i),
      drift: driftOf(levels),
      levels: levels,
      confidence: 60 + i,
      dominant: dominant,
      tz: formatTzOffset(Duration.zero),
    );
  }

  @override
  bool get simulated => true;

  @override
  Future<List<DayDrift>> driftDays(String fromDay, String toDay) async =>
      [for (final (i, _) in _story(fromDay, toDay)) dayAt(i)].reversed.toList();

  @override
  Future<int> dataDays(String fromDay, String toDay) async =>
      _story(fromDay, toDay).length;

  @override
  Future<Map<String, int>> checkins(String fromDay, String toDay) async => {
    for (final (i, day) in _story(fromDay, toDay))
      if (i >= _stableDrifts.length)
        day: _riseCheckins[i - _stableDrifts.length]
      else if (i.isEven)
        day: 4,
  };

  @override
  Future<List<DailyLimit>> limits() async => const [];

  @override
  Future<List<PhoneDay>> phoneDays(
    String fromDay,
    String toDay,
    List<DailyLimit> limits,
  ) async => [
    for (final (i, day) in _story(fromDay, toDay))
      PhoneDay(
        day: day,
        nightMinutes: i >= _stableDrifts.length
            ? _riseNightMinutes[i - _stableDrifts.length]
            : 5.0 + 2 * (i % 3),
        hasUsage: false,
      ),
  ];
}
