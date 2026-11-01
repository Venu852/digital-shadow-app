import 'dart:math' as math;

import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_repository.dart';
import 'package:test_app/suggest/experiment_engine.dart';
import 'package:test_app/suggest/suggest_store.dart';
import 'package:test_app/suggest/suggestion_builder.dart';
import 'package:test_app/ui/today_model.dart';

/// Days of history read for suggestions and experiment windows.
const int suggestionHistoryDays = 30;

/// A finished experiment's result stays on screen this long.
const int resultShownDays = 7;

class ExperimentCard {
  final Experiment experiment;

  /// What was tried, for the result sentence.
  final String text;
  final int dayNumber;

  /// For finished experiments.
  final String? resultText;
  final String? direction;

  const ExperimentCard(
    this.experiment,
    this.text,
    this.dayNumber, {
    this.resultText,
    this.direction,
  });
}

class SuggestionView {
  /// At most [maxSuggestions].
  final List<Suggestion> offered;
  final List<ExperimentCard> running;
  final List<ExperimentCard> results;

  const SuggestionView(this.offered, this.running, this.results);

  static const SuggestionView empty = SuggestionView([], [], []);

  bool get isEmpty => offered.isEmpty && running.isEmpty && results.isEmpty;
}

/// What was tried for a suggestion key, for the result sentence.
String experimentText(String key, List<DailyLimit> limits) {
  if (key.startsWith('sig:')) {
    return personalSuggestionTexts[key.substring(4)] ?? key;
  }
  if (key == nightNudgeKey) {
    return 'Try putting the phone away 30 minutes earlier.';
  }
  return 'A lower daily limit or a quiet hour for '
      '${_limitName(key, limits) ?? 'this app'}';
}

String? _limitName(String key, List<DailyLimit> limits) {
  if (!key.startsWith(limitNudgePrefix)) return null;
  final k = key.substring(limitNudgePrefix.length);
  return limits.where((l) => l.key == k).firstOrNull?.name;
}

/// Loads suggestions and experiments and applies the person's choices.
/// Everything stays on the phone.
class SuggestionService {
  final DriftRepository repository;
  final SuggestStore store;
  final DateTime Function() _clock;

  SuggestionService({
    required this.repository,
    required this.store,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Stores whose running experiments were checked since the app opened.
  static final Set<SuggestStore> _checked = Set.identity();

  /// Forgets the once-per-open check (tests).
  static void resetOpenCheck() => _checked.clear();

  String get _today {
    final n = _clock();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }

  /// [context] is the personal context, which lowers the displayed drift.
  Future<SuggestionView> load({String? context}) async {
    final today = _today;
    final from = addDays(today, -suggestionHistoryDays);
    final yesterday = addDays(today, -1);
    final drift = await repository.driftDays(from, yesterday);
    final limits = await repository.limits();
    final phone = await repository.phoneDays(from, yesterday, limits);
    var experiments = await store.experiments();

    if (_checked.add(store)) {
      final now = _clock();
      for (final e in experiments.where((e) => e.running)) {
        final values = measuredValues(
          e.key,
          driftDays: drift,
          phoneDays: phone,
          limits: limits,
        );
        final done = evaluateExperiment(e, values, today, now);
        if (done == null) continue;
        await store.updateExperiment(done);
        await store.putState(
          stateAfter(e.key, SuggestionAction.finished, today),
        );
      }
      experiments = await store.experiments();
    }

    final latest = drift.isEmpty ? null : drift.first;
    final raw = latest?.drift;
    final shown = raw == null
        ? null
        : personalContexts.contains(context)
        ? math.max(0, raw - contextDamp)
        : raw;
    final candidates = buildSuggestions(
      today: today,
      drift: shown,
      levels: latest?.levels ?? const {},
      limits: limits,
      phoneDays: phone,
    );
    final offered = selectSuggestions(candidates, await store.states(), today);

    final running = [
      for (final e in experiments)
        if (e.running)
          ExperimentCard(
            e,
            experimentText(e.key, limits),
            experimentDayNumber(e, today),
          ),
    ];
    final shownFrom = _clock().toUtc().subtract(
      const Duration(days: resultShownDays),
    );
    final results = [
      for (final e in experiments)
        if (e.status == ExperimentStatus.done &&
            (DateTime.tryParse(e.finishedAt ?? '')?.isAfter(shownFrom) ??
                false))
          ExperimentCard(
            e,
            experimentText(e.key, limits),
            experimentDays,
            resultText: experimentResultText(
              e,
              experimentText(e.key, limits),
              limitName: _limitName(e.key, limits),
            ),
            direction: experimentDirection(e),
          ),
    ];
    return SuggestionView(offered, running, results);
  }

  /// "Try for a week". Nothing happens when that suggestion is already
  /// being tried.
  Future<void> tryForWeek(Suggestion s) async {
    final today = _today;
    final existing = await store.experiments();
    if (existing.any((e) => e.running && e.key == s.key)) return;
    await store.addExperiment(startExperiment(s, today));
    await store.putState(stateAfter(s.key, SuggestionAction.tryForWeek, today));
  }

  /// Hidden for 14 days.
  Future<void> notNow(Suggestion s) =>
      store.putState(stateAfter(s.key, SuggestionAction.notNow, _today));

  /// Hidden for 60 days.
  Future<void> notUseful(Suggestion s) =>
      store.putState(stateAfter(s.key, SuggestionAction.notUseful, _today));

  /// "Stop experiment": cancelled, and the suggestion rests for 14 days.
  Future<void> stop(Experiment e) async {
    await store.updateExperiment(cancelExperiment(e, _clock()));
    await store.putState(stateAfter(e.key, SuggestionAction.finished, _today));
  }
}
