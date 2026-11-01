import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/suggest/suggestion_builder.dart';

const String today = '2026-11-01';

const Map<String, int?> levels = {
  'switching': 30,
  'session': 50,
  'checks': 50,
  'screen': 10,
  'night': 70,
  'timing': 12,
};

const DailyLimit social = DailyLimit('limit_min_social', 'Social media', 60);

/// The 7 completed days before [today], with [over] of them over 60
/// minutes of social media and [late] of them over 30 late-night minutes.
List<PhoneDay> week({int over = 0, int late = 0}) => [
  for (var i = 1; i <= 7; i++)
    PhoneDay(
      day: addDays(today, -i),
      nightMinutes: i <= late ? 45 : 30,
      limitMinutes: {'limit_min_social': i <= over ? 75 : 60},
    ),
];

SuggestionState? hiddenUntil(String status, String until) =>
    SuggestionState('sig:night', status, today, until);

void main() {
  group('signal-based suggestions', () {
    test('need a displayed drift of 20 or more', () {
      expect(
        buildSuggestions(today: today, drift: 19, levels: levels),
        isEmpty,
      );
      expect(buildSuggestions(today: today, levels: levels), isEmpty);
      expect(
        buildSuggestions(today: today, drift: 20, levels: levels),
        hasLength(2),
      );
    });

    test('come from the two highest levels, ties in signal order', () {
      final s = buildSuggestions(today: today, drift: 40, levels: levels);
      expect(s.map((x) => x.key), ['sig:night', 'sig:session']);
      expect(s.first.kind, SuggestionKind.signal);
      expect(
        s.first.text,
        'Try putting the phone away 30 minutes earlier tonight.',
      );
      expect(
        s.first.because,
        'Because you are using the phone more between midnight and 5am '
        'than usual.',
      );
      expect(
        s[1].text,
        'Try one longer, uninterrupted block today, even 25 minutes.',
      );
    });

    test('every signal has its text', () {
      for (final k in signalKeys) {
        expect(personalSuggestionTexts[k], isNotNull);
      }
    });
  });

  group('limit nudge', () {
    test('needs 3 of the last 7 days over the limit', () {
      expect(
        buildSuggestions(
          today: today,
          limits: [social],
          phoneDays: week(over: 2),
        ),
        isEmpty,
      );
      final s = buildSuggestions(
        today: today,
        limits: [social],
        phoneDays: week(over: 3),
      );
      expect(s.single.key, 'nudge:limit:limit_min_social');
      expect(
        s.single.text,
        'Social media went over your limit on 3 of the last 7 days. '
        'Would a lower daily limit or a quiet hour help?',
      );
    });

    test('exactly the limit is not over it, and today does not count', () {
      final days = [
        ...week(over: 2),
        const PhoneDay(day: today, limitMinutes: {'limit_min_social': 99}),
        PhoneDay(
          day: addDays(today, -8),
          limitMinutes: const {'limit_min_social': 99},
        ),
      ];
      expect(daysOverLimit(social, days, today), 2);
    });
  });

  group('night nudge', () {
    test('needs more than 30 late-night minutes on 3 of 7 days', () {
      expect(buildSuggestions(today: today, phoneDays: week(late: 2)), isEmpty);
      final s = buildSuggestions(today: today, phoneDays: week(late: 3));
      expect(s.single.key, nightNudgeKey);
      expect(
        s.single.text,
        'You used the phone after midnight on 3 of the last 7 days. Try '
        'putting it away 30 minutes earlier.',
      );
    });
  });

  group('state transitions', () {
    test('Not now hides for 14 days', () {
      final st = stateAfter('sig:night', SuggestionAction.notNow, today);
      expect(st.status, SuggestionStatus.notNow);
      expect(st.since, today);
      expect(st.hides(addDays(today, 13)), isTrue);
      expect(st.hides(addDays(today, 14)), isFalse);
    });

    test('Not useful hides for 60 days', () {
      final st = stateAfter('sig:night', SuggestionAction.notUseful, today);
      expect(st.status, SuggestionStatus.notUseful);
      expect(st.hides(addDays(today, 59)), isTrue);
      expect(st.hides(addDays(today, 60)), isFalse);
    });

    test('Try for a week hides while trying, whatever the date', () {
      final st = stateAfter('sig:night', SuggestionAction.tryForWeek, today);
      expect(st.status, SuggestionStatus.trying);
      expect(st.until, addDays(today, 6));
      expect(st.hides(addDays(today, 30)), isTrue);
    });

    test('a finished experiment rests for 14 days', () {
      final st = stateAfter('sig:night', SuggestionAction.finished, today);
      expect(st.status, SuggestionStatus.done);
      expect(st.hides(addDays(today, 13)), isTrue);
      expect(st.hides(addDays(today, 14)), isFalse);
    });

    test('a row round-trips', () {
      final st = stateAfter('nudge:night', SuggestionAction.notNow, today);
      final back = SuggestionState.fromRow(st.toRow());
      expect(back.key, st.key);
      expect(back.status, st.status);
      expect(back.since, st.since);
      expect(back.until, st.until);
    });
  });

  group('selectSuggestions', () {
    final all = buildSuggestions(
      today: today,
      drift: 40,
      levels: levels,
      limits: [social],
      phoneDays: week(over: 3, late: 4),
    );

    test('caps at 2 with signal-based first', () {
      expect(all, hasLength(4));
      final picked = selectSuggestions(all.reversed.toList(), {}, today);
      // Nudges listed first still come after the signal-based ones.
      expect(picked.map((s) => s.key), ['sig:session', 'sig:night']);
    });

    test('skips ones being tried', () {
      final picked = selectSuggestions(all, {
        'sig:night': stateAfter(
          'sig:night',
          SuggestionAction.tryForWeek,
          today,
        ),
      }, today);
      expect(picked.map((s) => s.key), [
        'sig:session',
        'nudge:limit:limit_min_social',
      ]);
    });

    test('skips hidden ones until their wait is over', () {
      final states = {
        'sig:night': hiddenUntil(SuggestionStatus.notNow, addDays(today, 14))!,
        'sig:session': hiddenUntil(
          SuggestionStatus.notUseful,
          addDays(today, 60),
        )!,
      };
      expect(selectSuggestions(all, states, today).map((s) => s.key), [
        'nudge:limit:limit_min_social',
        nightNudgeKey,
      ]);
      expect(
        selectSuggestions(all, states, addDays(today, 14)).map((s) => s.key),
        ['sig:night', 'nudge:limit:limit_min_social'],
      );
    });

    test('returns nothing when nothing applies', () {
      expect(selectSuggestions(const [], {}, today), isEmpty);
    });
  });
}
