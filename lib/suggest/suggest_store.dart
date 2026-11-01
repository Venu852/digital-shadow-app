import 'package:test_app/data/db.dart';
import 'package:test_app/suggest/experiment_engine.dart';
import 'package:test_app/suggest/suggestion_builder.dart';

/// Suggestion states and experiments. They stay on the phone and are
/// never uploaded.
abstract class SuggestStore {
  Future<Map<String, SuggestionState>> states();

  Future<void> putState(SuggestionState s);

  /// Newest first.
  Future<List<Experiment>> experiments();

  /// Returns [e] with its new id.
  Future<Experiment> addExperiment(Experiment e);

  Future<void> updateExperiment(Experiment e);
}

class DbSuggestStore implements SuggestStore {
  const DbSuggestStore();

  @override
  Future<Map<String, SuggestionState>> states() async => {
    for (final r in await ShadowDb.suggestionStates())
      '${r['key']}': SuggestionState.fromRow(r),
  };

  @override
  Future<void> putState(SuggestionState s) =>
      ShadowDb.putSuggestionState(s.toRow());

  @override
  Future<List<Experiment>> experiments() async =>
      (await ShadowDb.experiments()).map(Experiment.fromRow).toList();

  @override
  Future<Experiment> addExperiment(Experiment e) async =>
      e.copyWith(id: await ShadowDb.insertExperiment(e.toRow()));

  @override
  Future<void> updateExperiment(Experiment e) =>
      ShadowDb.updateExperiment(e.id!, e.toRow());
}

/// Kept in memory only: demo mode and tests.
class MemorySuggestStore implements SuggestStore {
  final Map<String, SuggestionState> stateRows = {};
  final List<Experiment> experimentRows = [];

  @override
  Future<Map<String, SuggestionState>> states() async => Map.of(stateRows);

  @override
  Future<void> putState(SuggestionState s) async => stateRows[s.key] = s;

  @override
  Future<List<Experiment>> experiments() async =>
      experimentRows.reversed.toList();

  @override
  Future<Experiment> addExperiment(Experiment e) async {
    final saved = e.copyWith(id: experimentRows.length + 1);
    experimentRows.add(saved);
    return saved;
  }

  @override
  Future<void> updateExperiment(Experiment e) async {
    final i = experimentRows.indexWhere((x) => x.id == e.id);
    if (i >= 0) experimentRows[i] = e;
  }
}
