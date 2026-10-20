import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/app_categories.dart';
import 'package:test_app/service/usage_reader.dart';
import 'package:test_app/service/usage_sync.dart';

const String _ownPackage = 'com.example.test_app';

class _Row {
  final String day;
  final String package;
  final String label;
  final int ms;
  final int sessions;
  final AppCategory cat;
  const _Row({
    required this.day,
    required this.package,
    required this.label,
    required this.ms,
    required this.sessions,
    required this.cat,
  });
}

class _AppAgg {
  final String package;
  final String label;
  final AppCategory cat;
  int ms = 0;
  int sessions = 0;
  _AppAgg(this.package, this.label, this.cat);
}

class UsageSummaryScreen extends StatefulWidget {
  const UsageSummaryScreen({super.key});

  @override
  State<UsageSummaryScreen> createState() => _UsageSummaryScreenState();
}

class _UsageSummaryScreenState extends State<UsageSummaryScreen>
    with WidgetsBindingObserver {
  bool _access = false;
  bool _loading = true;
  String _error = '';
  int _days = 1;
  List<_Row> _rows = [];
  Map<AppCategory, int> _limits = {};
  Map<String, int> _appLimits = {};
  List<int> _hourly = List<int>.filled(24, 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final ok = await UsageReader.hasAccess();
      if (ok) await UsageSync.syncRecentDays(days: _days == 1 ? 1 : 7);
      await _loadRows();
      if (mounted) setState(() => _access = ok);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load usage: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRows() async {
    final now = DateTime.now();
    final to = UsageSync.dayKey(now);
    final from =
    UsageSync.dayKey(DateTime(now.year, now.month, now.day - 6));
    final raw = await ShadowDb.usageRows(from, to);
    final rows = <_Row>[];
    for (final m in raw) {
      final pkg = '${m['package']}';
      final label = '${m['label']}';
      // Hide system components (no readable app name) and this app itself.
      if (label == pkg || pkg == _ownPackage) continue;
      rows.add(_Row(
        day: '${m['day']}',
        package: pkg,
        label: label,
        ms: ((m['total_ms'] as num?) ?? 0).toInt(),
        sessions: ((m['sessions'] as num?) ?? 0).toInt(),
        cat: categoryFor(pkg, ((m['category'] as num?) ?? -1).toInt()),
      ));
    }
    final limits = <AppCategory, int>{};
    for (final c in AppCategory.values) {
      final v = await ShadowDb.getSetting('limit_min_${c.name}');
      final n = int.tryParse(v ?? '');
      if (n != null && n > 0) limits[c] = n;
    }
    final appLimits = <String, int>{};
    final stored = await ShadowDb.getSettingsByPrefix('limit_app_');
    stored.forEach((k, v) {
      final n = int.tryParse(v);
      if (n != null && n > 0) {
        appLimits[k.substring('limit_app_'.length)] = n;
      }
    });
    final rangeFrom = UsageSync.dayKey(
        DateTime(now.year, now.month, now.day - (_days - 1)));
    final hourly = await ShadowDb.hourlyTotals(rangeFrom, to);
    if (mounted) {
      setState(() {
        _rows = rows;
        _limits = limits;
        _appLimits = appLimits;
        _hourly = hourly;
      });
    }
  }

  String get _today => UsageSync.dayKey(DateTime.now());

  List<_Row> get _rangeRows {
    final now = DateTime.now();
    final from = UsageSync.dayKey(
        DateTime(now.year, now.month, now.day - (_days - 1)));
    return _rows.where((r) => r.day.compareTo(from) >= 0).toList();
  }

  /// Average daily time in a category over earlier days that have data.
  /// Needs at least 3 earlier days, otherwise returns null.
  double? _usual(AppCategory c) {
    final today = _today;
    final perDay = <String, int>{};
    for (final r in _rows) {
      if (r.day == today) continue;
      perDay[r.day] = (perDay[r.day] ?? 0) + (r.cat == c ? r.ms : 0);
    }
    if (perDay.length < 3) return null;
    final sum = perDay.values.fold<int>(0, (s, v) => s + v);
    final avg = sum / perDay.length;
    return avg > 0 ? avg : null;
  }

  String _fmt(int ms) {
    final m = (ms / 60000).round();
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${m % 60}m';
  }

  /// Asks for a number of minutes. Returns null if cancelled, otherwise the
  /// typed text (empty means "clear the limit").
  Future<String?> _promptMinutes(String title, int? current) async {
    final ctrl = TextEditingController(text: current?.toString() ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: 'Minutes per day (empty to clear)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    return saved == true ? ctrl.text.trim() : null;
  }

  Future<void> _saveLimit(String key, String? text) async {
    if (text == null) return;
    final n = int.tryParse(text);
    await ShadowDb.setSetting(key, (n != null && n > 0) ? '$n' : '');
    await _loadRows();
  }

  Future<void> _editLimit(AppCategory c) async {
    final text = await _promptMinutes('Daily limit: ${c.label}', _limits[c]);
    await _saveLimit('limit_min_${c.name}', text);
  }

  Future<void> _editAppLimit(String package, String label) async {
    final text =
    await _promptMinutes('Daily limit: $label', _appLimits[package]);
    await _saveLimit('limit_app_$package', text);
  }

  Widget _hourChart() {
    final maxH = _hourly.fold<int>(0, (m, v) => v > m ? v : m);
    final totalH = _hourly.fold<int>(0, (s, v) => s + v);
    if (totalH <= 0) return const SizedBox.shrink();
    final late = _hourly.sublist(0, 5).fold<int>(0, (s, v) => s + v);
    final latePct = (late * 100 / totalH).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Usage by hour of day',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(24, (h) {
                final frac = maxH == 0 ? 0.0 : _hourly[h] / maxH;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      height: 2 + 98 * frac,
                      color: h < 5
                          ? Colors.deepOrange
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 4),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('12am'),
              Text('6am'),
              Text('12pm'),
              Text('6pm'),
              Text('11pm'),
            ],
          ),
          const SizedBox(height: 4),
          Text('Late night (12am–5am): ${_fmt(late)} ($latePct% of total)'),
        ],
      ),
    );
  }

  Widget _catCard(AppCategory c, int ms, int total) {
    final limit = _limits[c];
    final usual = _days == 1 ? _usual(c) : null;
    final lines = <Widget>[];
    if (_days == 1 && limit != null) {
      final limMs = limit * 60000;
      lines.add(LinearProgressIndicator(
          value: (ms / limMs).clamp(0.0, 1.0).toDouble()));
      final over = ms - limMs;
      lines.add(Text(
        over > 0
            ? 'Over your ${limit}m limit by ${_fmt(over)}'
            : 'Limit ${limit}m, ${_fmt(limMs - ms)} left',
        style: TextStyle(color: over > 0 ? Colors.red : null),
      ));
    } else if (_days == 1) {
      lines.add(const Text('Tap to set a daily limit'));
    } else {
      final pct = total == 0 ? 0 : (ms * 100 / total).round();
      lines.add(Text('$pct% of total time'));
    }
    if (usual != null) {
      lines.add(Text('${(ms / usual).toStringAsFixed(1)}× your usual'));
    }
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: () => _editLimit(c),
        title: Text(c.label),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines,
        ),
        trailing: Text(_fmt(ms)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final range = _rangeRows;
    final total = range.fold<int>(0, (s, r) => s + r.ms);

    final catTotals = <AppCategory, int>{};
    final aggs = <String, _AppAgg>{};
    for (final r in range) {
      catTotals[r.cat] = (catTotals[r.cat] ?? 0) + r.ms;
      final a =
      aggs.putIfAbsent(r.package, () => _AppAgg(r.package, r.label, r.cat));
      a.ms += r.ms;
      a.sessions += r.sessions;
    }
    final catList = catTotals.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final apps = aggs.values.where((a) => a.ms > 0).toList()
      ..sort((a, b) => b.ms.compareTo(a.ms));
    final maxMs = apps.isEmpty ? 1 : apps.first.ms;

    final children = <Widget>[];
    if (!_access && !_loading) {
      children.add(Card(
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('To show app usage, allow "Usage access" for this '
                  'app. The data stays on this phone.'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => UsageReader.openSettings(),
                child: const Text('Open usage access settings'),
              ),
            ],
          ),
        ),
      ));
    }
    if (_access) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text('Total app time: ${_fmt(total)}',
            style: Theme.of(context).textTheme.titleLarge),
      ));
      if (_days == 1) {
        final over = <String>[];
        for (final e in catList) {
          final l = _limits[e.key];
          if (l != null && e.value > l * 60000) over.add(e.key.label);
        }
        for (final a in apps) {
          final l = _appLimits[a.package];
          if (l != null && a.ms > l * 60000) over.add(a.label);
        }
        if (over.isNotEmpty) {
          children.add(Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Over limit today: ${over.join(', ')}',
                style: const TextStyle(color: Colors.red)),
          ));
        }
      }
      children.add(_hourChart());

      if (apps.isEmpty && !_loading) {
        children.add(const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No usage recorded for this period yet.'),
        ));
      }
      if (catList.isNotEmpty) {
        children.add(const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('By category',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ));
        for (final e in catList) {
          children.add(_catCard(e.key, e.value, total));
        }
      }
      if (apps.isNotEmpty) {
        children.add(const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Top apps',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ));
        for (final a in apps) {
          final limit = _appLimits[a.package];
          final limMs = limit == null ? 0 : limit * 60000;
          final showLimit = _days == 1 && limit != null;
          children.add(ListTile(
            onTap: () => _editAppLimit(a.package, a.label),
            title: Text(a.label),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(
                    value: showLimit
                        ? (a.ms / limMs).clamp(0.0, 1.0).toDouble()
                        : a.ms / maxMs),
                const SizedBox(height: 4),
                Text('${a.cat.label} · ${a.sessions} opens'),
                if (showLimit)
                  Text(
                    a.ms > limMs
                        ? 'Over your ${limit}m limit by ${_fmt(a.ms - limMs)}'
                        : 'Limit ${limit}m, ${_fmt(limMs - a.ms)} left',
                    style: TextStyle(color: a.ms > limMs ? Colors.red : null),
                  ),
              ],
            ),
            trailing: Text(_fmt(a.ms)),
          ));
        }
      }
      children.add(const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Time an app was on screen, from Android usage stats. System '
              'components and this app are hidden. Categories come from a '
              'built-in list and Android\'s own app category, so some apps may '
              'show as Other. Limits and comparisons use only your own usage.',
          style: TextStyle(fontSize: 12),
        ),
      ));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('App usage')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('7 days')),
              ],
              selected: {_days},
              onSelectionChanged: (s) {
                setState(() => _days = s.first);
                _refresh();
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}