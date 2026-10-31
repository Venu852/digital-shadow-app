import 'dart:math' as math;

import 'package:test_app/drift/drift_engine.dart';

/// Local-only labels a person can set for a stretch of unusual days.
const List<String> personalContexts = [
  'Travelling',
  'Exams',
  'Holiday',
  'Busy period',
  'New routine',
];

const String personalContextKey = 'personal_context';

/// How much an active personal context lowers the displayed drift.
const int contextDamp = 15;

const Map<DriftBand, String> bandSentences = {
  DriftBand.stable: 'Your rhythm is close to your usual.',
  DriftBand.early: 'Your rhythm is moving a little away from your usual.',
  DriftBand.elevated: 'Your rhythm has moved noticeably from your usual.',
  DriftBand.high: 'Your rhythm has moved a lot from your usual.',
};

/// "Sat 31 Oct" for a yyyy-MM-dd day.
String formatDay(String day) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final d = DateTime.parse(day);
  return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
}

class TodayModel {
  /// True when there is no established score for the latest completed day.
  final bool calibrating;

  /// 0-[minBaselineDays]: completed days with data, capped.
  final int calibrationDay;

  /// The latest completed day that was scored, if any.
  final String? asOfDay;
  final int? rawDrift;

  /// [rawDrift] after the personal context damp.
  final int? shownDrift;
  final DriftBand? band;
  final int confidence;
  final int observedDays;
  final String horizon;
  final String? context;

  const TodayModel({
    required this.calibrating,
    required this.calibrationDay,
    required this.asOfDay,
    required this.rawDrift,
    required this.shownDrift,
    required this.band,
    required this.confidence,
    required this.observedDays,
    required this.horizon,
    required this.context,
  });

  String get calibrationText =>
      'Day $calibrationDay of $minBaselineDays. No score until your own '
      'baseline exists.';

  String? get asOfText =>
      asOfDay == null ? null : 'As of ${formatDay(asOfDay!)}';

  String? get bandSentence => band == null ? null : bandSentences[band];

  String get observedText =>
      'based on $observedDays day${observedDays == 1 ? '' : 's'} observed';

  String? get contextLine => context == null || rawDrift == null
      ? null
      : 'Context active: $context. Raw $rawDrift, shown as $shownDrift.';
}

/// [days] are completed drift days, newest first. [dataDays] counts the
/// completed days with any stored data in the baseline window.
TodayModel buildTodayModel(
  List<DayDrift> days, {
  required int dataDays,
  String? context,
}) {
  final latest = days.isEmpty ? null : days.first;
  final ctx = personalContexts.contains(context) ? context : null;
  final raw = latest?.drift;
  final shown = raw == null
      ? null
      : (ctx == null ? raw : math.max(0, raw - contextDamp));
  final established = [
    for (final d in days.reversed)
      if (d.drift != null) d.drift!,
  ];
  return TodayModel(
    calibrating: raw == null,
    calibrationDay: math.min(minBaselineDays, math.max(0, dataDays)),
    asOfDay: latest?.day,
    rawDrift: raw,
    shownDrift: shown,
    band: shown == null ? null : driftBand(shown),
    confidence: latest?.confidence ?? 0,
    observedDays: dataDays,
    horizon: horizonFor(established),
    context: ctx,
  );
}

enum BannerKind {
  usageAccess,
  signedOut,
  sharingPaused,
  usageStale,
  sessionEnded,
}

class DataBanner {
  final BannerKind kind;
  final String text;

  /// Button label, or null for a banner without an action.
  final String? action;

  const DataBanner(this.kind, this.text, {this.action});
}

class BannerState {
  final DateTime now;
  final bool usageAccess;

  /// True when this phone was paired and the server signed it out.
  final bool signedOut;
  final DateTime? sharingPausedSince;

  /// Newest local day with stored app usage, if any.
  final String? lastUsageDay;
  final DateTime? lastSessionStart;
  final bool lastSessionEnded;
  final bool sessionRunning;

  const BannerState({
    required this.now,
    this.usageAccess = true,
    this.signedOut = false,
    this.sharingPausedSince,
    this.lastUsageDay,
    this.lastSessionStart,
    this.lastSessionEnded = true,
    this.sessionRunning = false,
  });
}

const int maxBanners = 2;

String _localDay(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-'
    '${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

/// At most [maxBanners] data-quality banners, most important first.
List<DataBanner> bannersFor(BannerState s) {
  final out = <DataBanner>[];
  if (!s.usageAccess) {
    out.add(
      const DataBanner(
        BannerKind.usageAccess,
        'Usage access is off, so app usage cannot update',
        action: 'Open settings',
      ),
    );
  }
  if (s.signedOut) {
    out.add(
      const DataBanner(
        BannerKind.signedOut,
        'Signed out of the server. Pair again in Privacy.',
      ),
    );
  }
  final since = s.sharingPausedSince;
  if (since != null) {
    final days = s.now.toUtc().difference(since.toUtc()).inDays;
    if (days >= 7) {
      out.add(
        DataBanner(
          BannerKind.sharingPaused,
          'Sharing has been paused for $days days. Resume?',
          action: 'Resume',
        ),
      );
    }
  }
  final last = s.lastUsageDay;
  if (s.usageAccess && last != null) {
    // Calendar days, in UTC so a daylight-saving change cannot shorten one.
    final gap = DateTime.parse('${_localDay(s.now)}T00:00:00Z')
        .difference(DateTime.parse('${last}T00:00:00Z'))
        .inDays;
    if (gap >= 3) {
      out.add(
        DataBanner(
          BannerKind.usageStale,
          'App usage has not updated for $gap days.',
        ),
      );
    }
  }
  final start = s.lastSessionStart;
  if (start != null &&
      !s.lastSessionEnded &&
      !s.sessionRunning &&
      s.now.difference(start) > const Duration(hours: 12)) {
    out.add(
      const DataBanner(
        BannerKind.sessionEnded,
        'Your last session ended unexpectedly. Battery settings can stop '
        'sessions in the background.',
        action: 'Battery settings',
      ),
    );
  }
  return out.take(maxBanners).toList();
}
