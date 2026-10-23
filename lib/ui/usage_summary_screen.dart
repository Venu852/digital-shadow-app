import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/app_categories.dart';
import 'package:test_app/service/usage_reader.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/service/usage_model.dart';

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
  Map<String, int> _behavior = {};
  UsageInsights? _insights;
  int? _selHour;

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
    final behavior = await ShadowDb.behaviorTotals(rangeFrom, to);
    final behRows = await ShadowDb.behaviorRows(from, to);
    final fgRows = await ShadowDb.hourlyForeground(from, to);
    final insights = analyzeUsage(
      behaviorRows: behRows,
      fgRows: fgRows,
      now: now,
      todayKey: to,
    );
    if (mounted) {
      setState(() {
        _rows = rows;
        _limits = limits;
        _appLimits = appLimits;
        _hourly = hourly;
        _behavior = behavior;
        _insights = insights;
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

  String _hourLabel(int h) {
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12${h < 12 ? 'am' : 'pm'}';
  }

  String _hourRange(int h) => '${_hourLabel(h)}–${_hourLabel((h + 1) % 24)}';

  void _selectAt(double dx, double width, {bool toggle = false}) {
    const left = _HourChartPainter.leftAxis;
    if (dx < left) return;
    final cellW = (width - left) / 24;
    final idx = ((dx - left) / cellW).floor().clamp(0, 23).toInt();
    setState(() => _selHour = (toggle && _selHour == idx) ? null : idx);
  }

  Widget _hourChart() {
    final totalH = _hourly.fold<int>(0, (s, v) => s + v);
    if (totalH <= 0) return const SizedBox.shrink();
    final late = _hourly.sublist(0, 5).fold<int>(0, (s, v) => s + v);
    final latePct = (late * 100 / totalH).round();
    final sel = _selHour;
    final scheme = Theme.of(context).colorScheme;
    final info = sel == null
        ? 'Tap or drag across the bars to see the exact hour'
        : '${_hourRange(sel)}: ${_fmt(_hourly[sel])} '
        '(${(_hourly[sel] * 100 / totalH).round()}% of total)';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _days == 1
                ? 'Usage by hour of day'
                : 'Usage by hour of day (all 7 days combined)',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            info,
            style: TextStyle(
              color: sel == null ? scheme.onSurfaceVariant : scheme.primary,
              fontWeight: sel == null ? FontWeight.normal : FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _selectAt(d.localPosition.dx, w, toggle: true),
              onHorizontalDragUpdate: (d) =>
                  _selectAt(d.localPosition.dx, w),
              child: CustomPaint(
                size: Size(w, 190),
                painter: _HourChartPainter(
                  values: _hourly,
                  selected: sel,
                  barColor: scheme.primary,
                  lateColor: Colors.deepOrange,
                  gridColor: scheme.outlineVariant,
                  textColor: scheme.onSurfaceVariant,
                ),
              ),
            );
          }),
          const SizedBox(height: 4),
          Text('Late night (12am–5am, orange bars): ${_fmt(late)} '
              '($latePct% of total)'),
        ],
      ),
    );
  }

  String _featLabel(String f, bool unlocks) {
    switch (f) {
      case 'pickups':
        return unlocks ? 'Unlocks' : 'Screen wake-ups';
      case 'opens':
        return 'App opens';
      case 'switches':
        return 'App switches';
      case 'apps':
        return 'Distinct apps';
      case 'fgMin':
        return 'Screen time';
      case 'screenMin':
        return 'Screen on';
      default:
        return f;
    }
  }

  String _featVal(String f, double v) {
    if (f == 'fgMin' || f == 'screenMin') return _fmt((v * 60000).round());
    return v.round().toString();
  }

  String _featExp(String f, double v) {
    if (f == 'fgMin' || f == 'screenMin') return _fmt((v * 60000).round());
    return v.toStringAsFixed(1);
  }

  Widget _insightsCard() {
    final ins = _insights;
    if (ins == null || ins.dataDays == 0) return const SizedBox.shrink();
    final lines = <Widget>[
      const Text('Insights (on-device model)',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
    ];
    if (!ins.ready) {
      lines.add(Text('Learning your usual patterns: ${ins.baselineDays} of '
          '$kMinBaselineDays earlier days available. Keep using the phone '
          'normally.'));
    } else {
      lines.add(Text(
        'Compared with your usual hours from ${ins.baselineDays} earlier '
            'days, split into night, morning, afternoon and evening.',
        style: const TextStyle(fontSize: 12),
      ));
      if (_days == 1) {
        lines.add(const SizedBox(height: 8));
        lines.add(const Text(
            'Predicted for today (so far + your usual for the rest of the day)',
            style: TextStyle(fontWeight: FontWeight.w600)));
        for (final f in const ['pickups', 'opens', 'fgMin', 'screenMin']) {
          final fc = ins.forecasts[f];
          if (fc == null) continue;
          lines.add(Text('${_featLabel(f, ins.unlocksReported)}: '
              '${_featVal(f, fc.total)} (usual day '
              '${_featVal(f, fc.usualTotal)}, so far '
              '${_featVal(f, fc.actualSoFar)})'));
        }
      }
      lines.add(const SizedBox(height: 8));
      final flags = _days == 1 ? ins.flagsToday : ins.flagsWeek;
      lines.add(Text(
          _days == 1 ? 'Unusual hours today' : 'Unusual hours this week',
          style: const TextStyle(fontWeight: FontWeight.w600)));
      if (flags.isEmpty) {
        lines.add(Text(_days == 1 ? 'None so far today.' : 'None this week.'));
      } else {
        for (final fl in flags.take(6)) {
          final day = _days == 1 ? '' : '${fl.sample.day.substring(5)}  ';
          lines.add(Text('$day${_hourRange(fl.sample.hour)}: '
              '${_featLabel(fl.topFeature, ins.unlocksReported)} '
              '${_featVal(fl.topFeature, fl.sample.f[fl.topFeature] ?? 0)} '
              '(usual ~${_featExp(fl.topFeature, fl.expected)}), '
              'unusually ${fl.topZ > 0 ? 'high' : 'low'}'));
        }
      }
    }
    lines.add(const SizedBox(height: 6));
    lines.add(const Text(
      'A statistical comparison with your own habits, not training. '
          'Unusual does not mean harmful.',
      style: TextStyle(fontSize: 11),
    ));
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines,
        ),
      ),
    );
  }

  Widget _behaviorCard() {
    final b = _behavior;
    final days = b['days'] ?? 0;
    if (days == 0) return const SizedBox.shrink();
    String v(String key) {
      final n = b[key] ?? 0;
      return _days == 1 ? '$n' : (n / days).toStringAsFixed(1);
    }

    final perDay = _days == 1 ? '' : ' (per day, average of $days days)';
    final screenMs = b['screen_ms'] ?? 0;
    final screenShown = _days == 1 ? screenMs : (screenMs / days).round();
    final noUnlock = (b['unlocks'] ?? 0) == 0 && (b['wakeups'] ?? 0) > 0;
    final events = UsageSync.lastTypeCounts.entries.toList()
      ..sort((a, c) =>
          (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(c.key) ?? 0));
    final eventText = events.map((e) => '${e.key}×${e.value}').join(', ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Behaviour$perDay',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Phone unlocks: ${v('unlocks')}'),
            Text('Screen wake-ups: ${v('wakeups')}'),
            Text('Screen on time: ${_fmt(screenShown)}'),
            Text('App opens: ${v('opens')}'),
            Text('App switches: ${v('switches')}'),
            Text('Distinct apps used: ${b['apps'] ?? 0}'),
            if (noUnlock)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'This phone did not report unlock events, so screen '
                      'wake-ups are the best signal.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            if (eventText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Event types reported today: $eventText',
                    style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
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
      children.add(_behaviorCard());
      children.add(_insightsCard());

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
                setState(() {
                  _days = s.first;
                  _selHour = null;
                });
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
class _HourChartPainter extends CustomPainter {
  static const double leftAxis = 40;
  static const double topPad = 18;
  static const double bottomAxis = 24;

  final List<int> values;
  final int? selected;
  final Color barColor;
  final Color lateColor;
  final Color gridColor;
  final Color textColor;

  const _HourChartPainter({
    required this.values,
    required this.selected,
    required this.barColor,
    required this.lateColor,
    required this.gridColor,
    required this.textColor,
  });

  static String _fmtMin(int m) {
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }

  static String _hourName(int h) {
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12${h < 12 ? 'am' : 'pm'}';
  }

  /// ax: 0 = text starts at pos, 0.5 = centered, 1 = ends at pos.
  /// ay: 0 = text top at pos, 0.5 = centered, 1 = text bottom at pos.
  void _drawText(Canvas canvas, String s, Offset pos,
      {double ax = 0.5, double ay = 0.0, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: textColor,
          fontSize: 10,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width * ax, pos.dy - tp.height * ay));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartW = size.width - leftAxis;
    final chartH = size.height - topPad - bottomAxis;
    final cellW = chartW / 24;
    final baseY = topPad + chartH;
    final sel = selected;

    var maxMs = 0;
    for (final v in values) {
      if (v > maxMs) maxMs = v;
    }
    final maxMin = maxMs / 60000.0;
    const steps = [5, 10, 15, 30, 60, 120, 180, 240, 360, 480, 720];
    var step = steps.last;
    for (final s in steps) {
      if (maxMin / s <= 3) {
        step = s;
        break;
      }
    }
    var nLines = (maxMin / step).ceil();
    if (nLines < 1) nLines = 1;
    final axisMaxMin = (nLines * step).toDouble();
    double yOf(double minutes) => baseY - (minutes / axisMaxMin) * chartH;

    // Highlight band behind the selected hour.
    if (sel != null) {
      canvas.drawRect(
        Rect.fromLTWH(leftAxis + sel * cellW, topPad, cellW, chartH),
        Paint()..color = textColor.withValues(alpha: 0.10),
      );
    }

    // Horizontal gridlines with labels.
    final gridPaint = Paint()..strokeWidth = 1;
    for (var k = 0; k <= nLines; k++) {
      final y = yOf((k * step).toDouble());
      gridPaint.color = k == 0 ? textColor : gridColor;
      canvas.drawLine(Offset(leftAxis, y), Offset(size.width, y), gridPaint);
      _drawText(canvas, _fmtMin(k * step), Offset(leftAxis - 6, y),
          ax: 1, ay: 0.5);
    }

    // Bars.
    for (var h = 0; h < 24; h++) {
      final v = values[h] / 60000.0;
      if (v <= 0) continue;
      final cx = leftAxis + (h + 0.5) * cellW;
      final barW = cellW * 0.7;
      var barH = v / axisMaxMin * chartH;
      if (barH < 1) barH = 1;
      final rect = Rect.fromLTWH(cx - barW / 2, baseY - barH, barW, barH);
      final rrect = RRect.fromRectAndCorners(
        rect,
        topLeft: const Radius.circular(2),
        topRight: const Radius.circular(2),
      );
      final base = h < 5 ? lateColor : barColor;
      final isSel = sel == h;
      final color =
      sel == null || isSel ? base : base.withValues(alpha: 0.35);
      canvas.drawRRect(rrect, Paint()..color = color);
      if (isSel) {
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = textColor,
        );
        _drawText(canvas, _fmtMin((values[h] / 60000).round()),
            Offset(cx, rect.top - 3),
            ax: 0.5, ay: 1.0, bold: true);
      }
    }

    // X axis: a tick under every bar, a label under every third bar.
    final tickPaint = Paint()
      ..color = textColor
      ..strokeWidth = 1;
    for (var h = 0; h < 24; h++) {
      final cx = leftAxis + (h + 0.5) * cellW;
      final major = h % 3 == 0;
      canvas.drawLine(
          Offset(cx, baseY), Offset(cx, baseY + (major ? 6 : 3)), tickPaint);
      if (major) {
        final nearSel = sel != null && sel != h && (sel - h).abs() <= 1;
        if (!nearSel) {
          _drawText(canvas, _hourName(h), Offset(cx, baseY + 8),
              ax: 0.5, ay: 0);
        }
      }
    }
    if (sel != null) {
      final cx = leftAxis + (sel + 0.5) * cellW;
      _drawText(canvas, _hourName(sel), Offset(cx, baseY + 8),
          ax: 0.5, ay: 0, bold: true);
    }
  }

  @override
  bool shouldRepaint(covariant _HourChartPainter old) =>
      old.values != values ||
          old.selected != selected ||
          old.barColor != barColor ||
          old.textColor != textColor;
}