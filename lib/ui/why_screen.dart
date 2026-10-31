import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_runner.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/today_model.dart';

const Map<String, String> signalCauses = {
  'switching': 'You are switching between apps more often than your usual.',
  'session': 'Your time in a single app is shorter than usual.',
  'checks': 'You are picking up the phone more often than your baseline.',
  'screen': 'Your screen-on time is above your usual.',
  'night': 'You are using the phone more between midnight and 5am than usual.',
  'timing': 'Your phone day is starting or ending at different times than '
      'usual.',
};

const Map<String, String> signalSources = {
  'switching': 'Measured from app usage events',
  'session': 'Measured from app usage events',
  'checks': 'Measured from unlocks or screen wake-ups',
  'screen': 'Measured from screen on and off events',
  'night': 'Measured from screen on and off events',
  'timing': 'Measured from when your first and last screen-on happen',
};

const String whyNote = 'This reading says your phone-use rhythm is shifting. '
    'It never states a diagnosis, a mental-health condition, or a judgement '
    'about you.';

class SignalShare {
  final String key;
  final int level;
  final int percent;

  const SignalShare(this.key, this.level, this.percent);
}

/// The six signals, highest level first (ties in signal order), each with
/// round(level / sum * 100). Missing signals count as [neutralLevel].
List<SignalShare> signalShares(Map<String, int?> levels) {
  final reported = {for (final k in signalKeys) k: levels[k] ?? neutralLevel};
  final sum = reported.values.fold<int>(0, (a, b) => a + b);
  final out = [
    for (final k in signalKeys)
      SignalShare(
          k,
          reported[k]!,
          sum == 0
              ? (100 / signalKeys.length).round()
              : (reported[k]! * 100 / sum).round())
  ];
  // List.sort is not stable, so ties fall back to the signal order.
  out.sort((a, b) => a.level != b.level
      ? b.level.compareTo(a.level)
      : signalKeys.indexOf(a.key).compareTo(signalKeys.indexOf(b.key)));
  return out;
}

/// "Without app switching your drift would be 22", or null when the day is
/// calibrating.
String? counterfactualText(DayDrift d) {
  if (!d.established) return null;
  final top = signalShares(d.levels).first.key;
  final without = driftWithout(d.levels, top);
  if (without == null) return null;
  return 'Without ${signalNames[top]!.toLowerCase()} your drift would be '
      '$without';
}

class WhyScreen extends StatefulWidget {
  /// Changes when the shell shows another tab; the screen reloads on visit.
  final ValueNotifier<int>? tab;
  final int index;

  const WhyScreen({super.key, this.tab, this.index = 2});

  @override
  State<WhyScreen> createState() => _WhyScreenState();
}

class _WhyScreenState extends State<WhyScreen> {
  bool _loaded = false;
  DayDrift? _latest;

  @override
  void initState() {
    super.initState();
    widget.tab?.addListener(_onTab);
    _load();
  }

  @override
  void dispose() {
    widget.tab?.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    if (widget.tab?.value == widget.index) _load();
  }

  Future<void> _load() async {
    try {
      final today = UsageSync.dayKey(DateTime.now());
      final rows = await ShadowDb.driftDays(
          addDays(today, -DriftRunner.days), addDays(today, -1));
      if (mounted) {
        setState(() {
          _latest = rows.isEmpty ? null : driftFromRow(rows.first);
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  void _howItWorks() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How this works'),
        content: const Text(
            'Each completed day, six signals are compared with your own '
            'earlier days. A fuller explanation is coming in a later '
            'version.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Widget _signalRow(SignalShare s) {
    final secondary = Theme.of(context).textTheme.bodySmall?.copyWith(
        color: ShadowColors.textSecondary);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(signalNames[s.key]!,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              Text('${s.percent}%',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 4),
          Text(signalCauses[s.key]!),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: s.percent / 100,
              minHeight: 4,
              color: ShadowColors.primary,
              backgroundColor: ShadowColors.border,
            ),
          ),
          const SizedBox(height: 4),
          Text(signalSources[s.key]!, style: secondary),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _latest;
    final children = <Widget>[];
    if (!_loaded) {
      children.add(const Center(child: CircularProgressIndicator()));
    } else if (d == null || !d.established) {
      children.add(Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Still learning your usual',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(d == null
                  ? 'No completed days scored yet. Once your own baseline '
                      'exists, this shows which signals moved most.'
                  : 'Calibrating. About ${d.needDays} more '
                      'day${d.needDays == 1 ? '' : 's'} of data are needed '
                      'before signals can be compared with your usual.'),
            ],
          ),
        ),
      ));
    } else {
      final cf = counterfactualText(d);
      children.addAll([
        Text('What moved on ${formatDay(d.day)}',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: Column(
              children: [for (final s in signalShares(d.levels)) _signalRow(s)],
            ),
          ),
        ),
        if (cf != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(cf),
          ),
      ]);
    }
    children.addAll([
      const SizedBox(height: 16),
      const Text(whyNote,
          style: TextStyle(color: ShadowColors.textSecondary)),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _howItWorks,
          child: const Text('How this works'),
        ),
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Why')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: children,
        ),
      ),
    );
  }
}
