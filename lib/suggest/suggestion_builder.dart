import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/why_screen.dart';

/// A displayed drift at or above this offers signal-based suggestions.
const int personalSuggestionThreshold = 20;

/// At most this many suggestions are shown at a time.
const int maxSuggestions = 2;

/// A nudge needs this many of the last [nudgeWindowDays] days.
const int nudgeMinDays = 3;
const int nudgeWindowDays = 7;

/// Late-night screen minutes (hours 0-4) above this count for the nudge.
const double nightNudgeMinutes = 30;

const int notNowDays = 14;
const int notUsefulDays = 60;

/// Offers, never alerts. Shown with "Because" and the self-voice cause.
const Map<String, String> personalSuggestionTexts = {
  'switching':
      'Try checking messages at set times instead of switching all day.',
  'session': 'Try one longer, uninterrupted block today, even 25 minutes.',
  'checks': 'Try leaving the phone out of reach for one hour.',
  'screen': 'Try a short screen-free break between long stretches.',
  'night': 'Try putting the phone away 30 minutes earlier tonight.',
  'timing':
      'Try keeping your first and last phone use of the day closer to '
      'your usual times.',
};

const String nightNudgeKey = 'nudge:night';

String signalSuggestionKey(String signal) => 'sig:$signal';

const String limitNudgePrefix = 'nudge:limit:';

String limitNudgeKey(String limitKey) => '$limitNudgePrefix$limitKey';

enum SuggestionKind { signal, limit, night }

class Suggestion {
  final String key;
  final SuggestionKind kind;

  /// The signal for signal-based suggestions.
  final String? signal;
  final String text;

  /// "Because ..." for signal-based suggestions.
  final String? because;

  const Suggestion({
    required this.key,
    required this.kind,
    required this.text,
    this.signal,
    this.because,
  });
}

/// A daily limit from settings: `limit_min_<category>` or
/// `limit_app_<package>`, with the name shown on this phone only.
class DailyLimit {
  final String key;
  final String name;
  final int minutes;

  const DailyLimit(this.key, this.name, this.minutes);
}

/// Phone-only totals for one completed day.
class PhoneDay {
  final String day;

  /// False when the day has no stored screen data.
  final bool hasScreen;
  final double nightMinutes;

  /// False when the day has no stored app usage.
  final bool hasUsage;

  /// Minutes used per limit key that day.
  final Map<String, double> limitMinutes;

  const PhoneDay({
    required this.day,
    this.hasScreen = true,
    this.nightMinutes = 0,
    this.hasUsage = true,
    this.limitMinutes = const {},
  });
}

String _because(String signal) {
  final cause = signalCauses[signal]!;
  return 'Because ${cause[0].toLowerCase()}${cause.substring(1)}';
}

String limitNudgeText(String name, int days) =>
    '$name went over your limit on $days of the last $nudgeWindowDays days. '
    'Would a lower daily limit or a quiet hour help?';

String nightNudgeText(int days) =>
    'You used the phone after midnight on $days of the last '
    '$nudgeWindowDays days. Try putting it away 30 minutes earlier.';

/// [phoneDays] from the 7 completed days before [today] that are used.
List<PhoneDay> _lastWeek(List<PhoneDay> phoneDays, String today) {
  final from = addDays(today, -nudgeWindowDays);
  return [
    for (final p in phoneDays)
      if (p.day.compareTo(from) >= 0 && p.day.compareTo(today) < 0) p,
  ];
}

/// Days of the last 7 completed days on which [limit] was exceeded.
int daysOverLimit(DailyLimit limit, List<PhoneDay> phoneDays, String today) =>
    _lastWeek(
      phoneDays,
      today,
    ).where((p) => (p.limitMinutes[limit.key] ?? 0) > limit.minutes).length;

/// Days of the last 7 completed days with more than 30 late-night minutes.
int lateNightDays(List<PhoneDay> phoneDays, String today) => _lastWeek(
  phoneDays,
  today,
).where((p) => p.hasScreen && p.nightMinutes > nightNudgeMinutes).length;

/// Every suggestion that applies, signal-based first. [drift] is the
/// latest displayed drift and [levels] that day's levels.
List<Suggestion> buildSuggestions({
  required String today,
  int? drift,
  Map<String, int?> levels = const {},
  List<DailyLimit> limits = const [],
  List<PhoneDay> phoneDays = const [],
}) {
  final out = <Suggestion>[];
  if (drift != null && drift >= personalSuggestionThreshold) {
    for (final s in signalShares(levels).take(maxSuggestions)) {
      out.add(
        Suggestion(
          key: signalSuggestionKey(s.key),
          kind: SuggestionKind.signal,
          signal: s.key,
          text: personalSuggestionTexts[s.key]!,
          because: _because(s.key),
        ),
      );
    }
  }
  for (final l in limits) {
    final n = daysOverLimit(l, phoneDays, today);
    if (n >= nudgeMinDays) {
      out.add(
        Suggestion(
          key: limitNudgeKey(l.key),
          kind: SuggestionKind.limit,
          text: limitNudgeText(l.name, n),
        ),
      );
    }
  }
  final nights = lateNightDays(phoneDays, today);
  if (nights >= nudgeMinDays) {
    out.add(
      Suggestion(
        key: nightNudgeKey,
        kind: SuggestionKind.night,
        text: nightNudgeText(nights),
      ),
    );
  }
  return out;
}

/// Values of suggestion_states.status.
class SuggestionStatus {
  static const String trying = 'trying';
  static const String notNow = 'not_now';
  static const String notUseful = 'not_useful';
  static const String done = 'done';
}

class SuggestionState {
  final String key;
  final String status;
  final String since;

  /// The first day the suggestion may show again; null means no wait.
  final String? until;

  const SuggestionState(this.key, this.status, this.since, this.until);

  /// True when the suggestion is not offered on [today].
  bool hides(String today) {
    if (status == SuggestionStatus.trying) return true;
    final u = until;
    return u != null && today.compareTo(u) < 0;
  }

  Map<String, Object?> toRow() => {
    'key': key,
    'status': status,
    'since': since,
    'until': until,
  };

  static SuggestionState fromRow(Map<String, Object?> r) => SuggestionState(
    '${r['key']}',
    '${r['status']}',
    '${r['since']}',
    r['until'] as String?,
  );
}

enum SuggestionAction { tryForWeek, notNow, notUseful, finished }

/// The state a suggestion moves to after [action] on [today]. A finished
/// or stopped experiment rests for [notNowDays] before it is offered again.
SuggestionState stateAfter(String key, SuggestionAction action, String today) {
  switch (action) {
    case SuggestionAction.tryForWeek:
      return SuggestionState(
        key,
        SuggestionStatus.trying,
        today,
        addDays(today, 6),
      );
    case SuggestionAction.notNow:
      return SuggestionState(
        key,
        SuggestionStatus.notNow,
        today,
        addDays(today, notNowDays),
      );
    case SuggestionAction.notUseful:
      return SuggestionState(
        key,
        SuggestionStatus.notUseful,
        today,
        addDays(today, notUsefulDays),
      );
    case SuggestionAction.finished:
      return SuggestionState(
        key,
        SuggestionStatus.done,
        today,
        addDays(today, notNowDays),
      );
  }
}

/// At most [maxSuggestions], signal-based first, leaving out the ones
/// being tried or hidden on [today].
List<Suggestion> selectSuggestions(
  List<Suggestion> candidates,
  Map<String, SuggestionState> states,
  String today,
) {
  final visible = [
    for (final s in candidates)
      if (!(states[s.key]?.hides(today) ?? false)) s,
  ];
  final signal = visible.where((s) => s.kind == SuggestionKind.signal);
  final other = visible.where((s) => s.kind != SuggestionKind.signal);
  return [...signal, ...other].take(maxSuggestions).toList();
}
