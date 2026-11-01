import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/suggest/experiment_engine.dart';
import 'package:test_app/suggest/suggestion_builder.dart';
import 'package:test_app/suggest/suggestion_service.dart';
import 'package:test_app/ui/demo_banner.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/today_model.dart';

/// The service over the current data: simulated in demo mode.
SuggestionService currentSuggestionService() =>
    SuggestionService(repository: DemoMode.repository, store: DemoMode.store);

Future<SuggestionView> loadSuggestionView() async {
  String? ctx;
  try {
    ctx = await ShadowDb.getSetting(personalContextKey);
  } catch (_) {
    // No context.
  }
  return currentSuggestionService().load(context: ctx);
}

const String suggestionsNote =
    'Suggestions are offers, not instructions. They and any experiment stay '
    'on this phone.';

const String noSuggestionsText =
    'Nothing to suggest right now. Suggestions appear when your rhythm moves '
    'away from your usual, or when a limit you set is often passed.';

const TextStyle _secondary = TextStyle(color: ShadowColors.textSecondary);

/// Running experiments, results and up to two suggestions with their
/// buttons. Used on the Suggestions screen and the Trends tab.
class SuggestionsPanel extends StatefulWidget {
  /// Called after any choice, so the parent can refresh its own summary.
  final VoidCallback? onChanged;

  const SuggestionsPanel({super.key, this.onChanged});

  @override
  State<SuggestionsPanel> createState() => _SuggestionsPanelState();
}

class _SuggestionsPanelState extends State<SuggestionsPanel> {
  SuggestionView? _view;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    DemoMode.enabled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    DemoMode.enabled.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final v = await loadSuggestionView();
      if (mounted) setState(() => _view = v);
    } catch (_) {
      if (mounted) setState(() => _view = SuggestionView.empty);
    }
  }

  Future<void> _act(Future<void> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (_) {
      // The card stays as it was.
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
      widget.onChanged?.call();
    }
  }

  Widget _card(List<Widget> children, {bool highlight = false}) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    color: highlight ? ShadowColors.selected : null,
    shape: highlight
        ? const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: ShadowColors.selectedBorder),
          )
        : null,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  Widget _running(ExperimentCard c) {
    final s = currentSuggestionService();
    return _card([
      Text(
        'Day ${c.dayNumber} of $experimentDays',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      Text(c.text),
      const SizedBox(height: 6),
      const Text(
        'The result appears after the week, when at least 5 days have data.',
        style: _secondary,
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: _busy
            ? null
            : () => _act(() => s.stop(c.experiment), 'Experiment stopped.'),
        child: const Text('Stop experiment'),
      ),
    ], highlight: true);
  }

  Widget _result(ExperimentCard c) => _card([
    const Text(
      'Experiment result',
      style: TextStyle(fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 6),
    Text(c.resultText!),
    if (c.direction != null) ...[
      const SizedBox(height: 6),
      Text(c.direction!, style: _secondary),
    ],
  ]);

  Widget _offer(Suggestion sug) {
    final s = currentSuggestionService();
    return _card([
      Text(sug.text, style: const TextStyle(fontWeight: FontWeight.w600)),
      if (sug.because != null) ...[
        const SizedBox(height: 6),
        Text(sug.because!, style: _secondary),
      ],
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            onPressed: _busy
                ? null
                : () => _act(
                    () => s.tryForWeek(sug),
                    'Experiment started. Day 1 of $experimentDays.',
                  ),
            child: const Text('Try for a week'),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () =>
                      _act(() => s.notNow(sug), 'Hidden for $notNowDays days.'),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _act(
                    () => s.notUseful(sug),
                    'Hidden for $notUsefulDays days.',
                  ),
            child: const Text('Not useful'),
          ),
        ],
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final v = _view;
    if (v == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in v.running) _running(c),
        for (final c in v.results) _result(c),
        for (final s in v.offered) _offer(s),
        if (v.offered.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(noSuggestionsText, style: _secondary),
          ),
      ],
    );
  }
}

class SuggestionsScreen extends StatelessWidget {
  const SuggestionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Suggestions')),
      body: Column(
        children: [
          const DemoBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                Text(suggestionsNote, style: _secondary),
                SizedBox(height: 12),
                SuggestionsPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Suggestions" card on Today: at most two offers and any running
/// experiment. Tapping it opens [SuggestionsScreen].
class SuggestionsSummaryCard extends StatelessWidget {
  final SuggestionView view;
  final VoidCallback onReturn;

  const SuggestionsSummaryCard({
    super.key,
    required this.view,
    required this.onReturn,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <Widget>[
      for (final c in view.running)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Trying, day ${c.dayNumber} of $experimentDays: ${c.text}',
          ),
        ),
      if (view.results.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('An experiment finished. Open to see the result.'),
        ),
      for (final s in view.offered.take(maxSuggestions))
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(s.text)),
      if (view.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Nothing to suggest right now.', style: _secondary),
        ),
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const SuggestionsScreen()));
          onReturn();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Suggestions',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    ...lines,
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: ShadowColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
