import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/today_model.dart';

DayDrift dd(String day, int? drift, {int confidence = 80}) => DayDrift(
      day: day,
      drift: drift,
      levels: {for (final k in signalKeys) k: drift},
      confidence: confidence,
      dominant: 'switching',
      tz: '+00:00',
      needDays: drift == null ? 2 : 0,
    );

void main() {
  group('buildTodayModel', () {
    test('no days at all is calibrating at day 0', () {
      final m = buildTodayModel(const [], dataDays: 0);
      expect(m.calibrating, isTrue);
      expect(m.calibrationText,
          'Day 0 of 5. No score until your own baseline exists.');
      expect(m.asOfText, isNull);
    });

    test('a calibrating latest day counts data days, capped at 5', () {
      final m = buildTodayModel([dd('2026-10-31', null)], dataDays: 3);
      expect(m.calibrating, isTrue);
      expect(m.calibrationDay, 3);
      expect(m.calibrationText,
          'Day 3 of 5. No score until your own baseline exists.');
      expect(
          buildTodayModel([dd('2026-10-31', null)], dataDays: 12)
              .calibrationDay,
          5);
    });

    test('established shows the latest completed day and its band', () {
      final m = buildTodayModel(
          [dd('2026-10-31', 30, confidence: 76), dd('2026-10-30', 10)],
          dataDays: 9);
      expect(m.calibrating, isFalse);
      expect(m.asOfDay, '2026-10-31');
      expect(m.asOfText, 'As of Sat 31 Oct');
      expect(m.rawDrift, 30);
      expect(m.shownDrift, 30);
      expect(m.band, DriftBand.early);
      expect(m.bandSentence,
          'Your rhythm is moving a little away from your usual.');
      expect(m.observedText, 'based on 9 days observed');
      expect(m.confidence, 76);
      expect(m.contextLine, isNull);
    });

    test('each band has its sentence', () {
      String s(int d) =>
          buildTodayModel([dd('2026-10-31', d)], dataDays: 6).bandSentence!;
      expect(s(5), 'Your rhythm is close to your usual.');
      expect(s(50), 'Your rhythm has moved noticeably from your usual.');
      expect(s(80), 'Your rhythm has moved a lot from your usual.');
    });

    test('a personal context damps the shown drift by 15', () {
      final m = buildTodayModel([dd('2026-10-31', 40)],
          dataDays: 6, context: 'Exams');
      expect(m.rawDrift, 40);
      expect(m.shownDrift, 25);
      expect(m.band, DriftBand.early);
      expect(m.contextLine, 'Context active: Exams. Raw 40, shown as 25.');
    });

    test('the damp never goes below zero', () {
      final m = buildTodayModel([dd('2026-10-31', 9)],
          dataDays: 6, context: 'Travelling');
      expect(m.shownDrift, 0);
      expect(m.contextLine, 'Context active: Travelling. Raw 9, shown as 0.');
    });

    test('an unknown context is ignored', () {
      final m = buildTodayModel([dd('2026-10-31', 40)],
          dataDays: 6, context: 'Nope');
      expect(m.shownDrift, 40);
      expect(m.contextLine, isNull);
    });

    test('the horizon uses established drifts oldest first', () {
      final days = [
        dd('2026-10-31', 40),
        dd('2026-10-30', 35),
        dd('2026-10-29', null),
        dd('2026-10-28', 32),
        dd('2026-10-27', 30),
      ];
      // Oldest first: 30, 32, 35, 40 -> slope 10.
      expect(buildTodayModel(days, dataDays: 9).horizon,
          '2 to 3 weeks if the trend continues');
    });
  });

  group('bannersFor', () {
    final now = DateTime(2026, 11, 1, 10);

    List<BannerKind> kinds(BannerState s) =>
        bannersFor(s).map((b) => b.kind).toList();

    test('nothing wrong gives no banners', () {
      expect(bannersFor(BannerState(now: now, lastUsageDay: '2026-11-01')),
          isEmpty);
    });

    test('each condition gives its banner', () {
      expect(kinds(BannerState(now: now, usageAccess: false)),
          [BannerKind.usageAccess]);
      expect(kinds(BannerState(now: now, signedOut: true)),
          [BannerKind.signedOut]);
      expect(
          kinds(BannerState(
              now: now,
              sharingPausedSince: now.subtract(const Duration(days: 6)))),
          isEmpty);
      final paused = bannersFor(BannerState(
          now: now, sharingPausedSince: now.subtract(const Duration(days: 8))));
      expect(paused.single.text, 'Sharing has been paused for 8 days. Resume?');
      expect(kinds(BannerState(now: now, lastUsageDay: '2026-10-30')), isEmpty);
      expect(kinds(BannerState(now: now, lastUsageDay: '2026-10-29')),
          [BannerKind.usageStale]);
    });

    test('an unexpected end needs an open row over 12 hours old and no run',
        () {
      final old = now.subtract(const Duration(hours: 13));
      BannerState s(DateTime start, {bool ended = false, bool running = false}) =>
          BannerState(
              now: now,
              lastSessionStart: start,
              lastSessionEnded: ended,
              sessionRunning: running);
      expect(kinds(s(old)), [BannerKind.sessionEnded]);
      expect(bannersFor(s(old)).single.action, 'Battery settings');
      expect(kinds(s(old, ended: true)), isEmpty);
      expect(kinds(s(old, running: true)), isEmpty);
      expect(kinds(s(now.subtract(const Duration(hours: 11)))), isEmpty);
    });

    test('at most two banners, in priority order', () {
      final all = bannersFor(BannerState(
        now: now,
        usageAccess: false,
        signedOut: true,
        sharingPausedSince: now.subtract(const Duration(days: 10)),
        lastUsageDay: '2026-10-01',
        lastSessionStart: now.subtract(const Duration(days: 1)),
        lastSessionEnded: false,
      ));
      expect(all.map((b) => b.kind),
          [BannerKind.usageAccess, BannerKind.signedOut]);
      expect(all.first.text, 'Usage access is off, so app usage cannot update');
      expect(all.first.action, 'Open settings');
      expect(all[1].text, 'Signed out of the server. Pair again in Privacy.');

      final rest = bannersFor(BannerState(
        now: now,
        sharingPausedSince: now.subtract(const Duration(days: 10)),
        lastUsageDay: '2026-10-01',
        lastSessionStart: now.subtract(const Duration(days: 1)),
        lastSessionEnded: false,
      ));
      expect(rest.map((b) => b.kind),
          [BannerKind.sharingPaused, BannerKind.usageStale]);
    });
  });
}
