import 'package:flutter/foundation.dart';
import 'package:test_app/demo/synthetic_drift_repository.dart';
import 'package:test_app/drift/drift_repository.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/suggest/suggest_store.dart';

/// Simulated data for showing the app. The switch lives in memory only,
/// so it is off again after the app restarts, and while it is on nothing
/// is written to the real tables or uploaded.
class DemoMode {
  static const String banner =
      'Demo data: simulated. Nothing is saved or uploaded.';

  static const String toggleLabel = 'Demo mode: simulated data';

  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static MemorySuggestStore? _store;

  static bool get on => enabled.value;

  /// Turning it off drops the in-memory suggestion states and experiments.
  static void set(bool value) {
    _store = null;
    enabled.value = value;
  }

  /// Drops the in-memory suggestion states and experiments.
  static void clearMemory() => _store = null;

  static DriftRepository get repository => on
      ? SyntheticDriftRepository(today: UsageSync.dayKey(DateTime.now()))
      : const DbDriftRepository();

  static SuggestStore get store =>
      on ? (_store ??= MemorySuggestStore()) : const DbSuggestStore();
}
