import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/ui/usage_summary_screen.dart';

String _two(int v) => v.toString().padLeft(2, '0');

String _hm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

String _hms(DateTime t) => '${_hm(t)}:${_two(t.second)}';

String _dm(DateTime? t) =>
    t == null ? '-' : '${_two(t.day)}/${_two(t.month)} ${_hm(t)}';

String _dur(Duration d) {
  final m = d.inMinutes;
  if (m < 60) return '$m min';
  return '${m ~/ 60}h ${m % 60}m';
}

class _Win {
  final DateTime ts;
  final double? score;
  final bool anomaly;
  final double? screen;
  final double? accel;
  final double? gyro;
  const _Win({
    required this.ts,
    required this.score,
    required this.anomaly,
    required this.screen,
    required this.accel,
    required this.gyro,
  });
}

class _Bucket {
  final DateTime start;
  final DateTime end;
  int count = 0;
  int scored = 0;
  int anomalies = 0;
  double maxScore = 0;
  double screenSum = 0;
  int screenN = 0;
  _Bucket(this.start, this.end);
  double? get avgScreen => screenN == 0 ? null : screenSum / screenN;
}

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  static const int _bucketCount = 60;

  int _hours = 6;
  bool _loading = true;
  String _error = '';
  List<_Win> _wins = [];
  List<_Bucket> _buckets = [];
  List<Map<String, Object?>> _sessions = [];
  int? _sel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final now = DateTime.now();
      final from = now.subtract(Duration(hours: _hours));
      final rows = await ShadowDb.windowsSince(from.toUtc().toIso8601String());
      final wins = <_Win>[];
      for (final r in rows) {
        try {
          final end = DateTime.parse('${r['end_ts']}').toLocal();
          final f = jsonDecode('${r['features_json']}') as Map<String, dynamic>;
          wins.add(_Win(
            ts: end,
            score: (r['score'] as num?)?.toDouble(),
            anomaly: ((r['is_anomaly'] as num?) ?? 0).toInt() == 1,
            screen: (f['screen_on_fraction'] as num?)?.toDouble(),
            accel: (f['accel_mag_mean'] as num?)?.toDouble(),
            gyro: (f['gyro_mag_mean'] as num?)?.toDouble(),
          ));
        } catch (_) {
          // Skip a window we can't read.
        }
      }

      final spanMs = now.difference(from).inMilliseconds / _bucketCount;
      final buckets = List.generate(
        _bucketCount,
            (i) => _Bucket(
          from.add(Duration(milliseconds: (spanMs * i).round())),
          from.add(Duration(milliseconds: (spanMs * (i + 1)).round())),
        ),
      );
      for (final w in wins) {
        var idx = (w.ts.difference(from).inMilliseconds / spanMs).floor();
        if (idx < 0) continue;
        if (idx >= _bucketCount) idx = _bucketCount - 1;
        final b = buckets[idx];
        b.count++;
        final s = w.score;
        if (s != null) {
          b.scored++;
          if (s > b.maxScore) b.maxScore = s;
        }
        if (w.anomaly) b.anomalies++;
        final sc = w.screen;
        if (sc != null) {
          b.screenSum += sc;
          b.screenN++;
        }
      }

      final sessions = await ShadowDb.recentSessions(5);
      if (mounted) {
        setState(() {
          _wins = wins;
          _buckets = buckets;
          _sessions = sessions;
          _sel = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load results: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _selectAt(double dx, double width, {bool toggle = false}) {
    const left = _ScorePainter.leftAxis;
    if (dx < left || _buckets.isEmpty) return;
    final cellW = (width - left) / _buckets.length;
    final idx =
    ((dx - left) / cellW).floor().clamp(0, _buckets.length - 1).toInt();
    setState(() => _sel = (toggle && _sel == idx) ? null : idx);
  }

  String _screenLabel(double? f) {
    if (f == null) return 'screen unknown';
    if (f >= 0.8) return 'screen on';
    if (f <= 0.2) return 'screen off';
    return 'screen partly on';
  }

  String _bucketInfo(_Bucket b) {
    final span = '${_hm(b.start)}–${_hm(b.end)}';
    if (b.count == 0) return '$span: no data (no session running)';
    final parts = <String>['${b.count} windows'];
    if (b.scored == 0) {
      parts.add('not scored yet (calibrating)');
    } else {
      parts.add('highest score ${b.maxScore.toStringAsFixed(2)}');
    }
    if (b.anomalies > 0) parts.add('${b.anomalies} flagged');
    final s = b.avgScreen;
    if (s != null) parts.add('screen on ${(s * 100).round()}%');
    return '$span: ${parts.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _wins.length;
    final scoredWins = _wins.where((w) => w.score != null).toList();
    final scored = scoredWins.length;
    final flaggedWins = _wins.where((w) => w.anomaly).toList();
    final flagged = flaggedWins.length;
    final avg = scored == 0
        ? null
        : scoredWins.map((w) => w.score ?? 0.0).reduce((a, b) => a + b) /
        scored;
    final sel = _sel;

    final children = <Widget>[
      SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 1, label: Text('1 hour')),
          ButtonSegment(value: 6, label: Text('6 hours')),
          ButtonSegment(value: 24, label: Text('24 hours')),
        ],
        selected: {_hours},
        onSelectionChanged: (s) {
          setState(() => _hours = s.first);
          _load();
        },
      ),
      const SizedBox(height: 8),
      if (_loading) const LinearProgressIndicator(),
      if (_error.isNotEmpty)
        Text(_error, style: const TextStyle(color: Colors.red)),
    ];

    if (!_loading && total == 0) {
      children.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text('No motion windows in this period. Start a session on '
            'the home screen to collect some.'),
      ));
    } else if (total > 0) {
      children.addAll([
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Windows recorded: $total'),
                Text('Scored: $scored (the rest were calibrating)'),
                Text('Flagged as unusual: $flagged'
                    '${scored == 0 ? '' : ' (${(flagged * 100 / scored).round()}% of scored)'}'),
                if (avg != null) Text('Average score: ${avg.toStringAsFixed(2)}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Motion score over time',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          sel == null
              ? 'Tap or drag across the bars for details'
              : _bucketInfo(_buckets[sel]),
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
            onHorizontalDragUpdate: (d) => _selectAt(d.localPosition.dx, w),
            child: CustomPaint(
              size: Size(w, 170),
              painter: _ScorePainter(
                buckets: _buckets,
                selected: sel,
                barColor: scheme.primary,
                flagColor: Colors.redAccent,
                gridColor: scheme.outlineVariant,
                textColor: scheme.onSurfaceVariant,
                mutedColor: scheme.outline,
              ),
            ),
          );
        }),
        const SizedBox(height: 4),
        const Text(
          'Red: contains flagged windows. Gray: not scored yet. The dashed '
              'line is the 0.5 flag threshold. Gaps mean no session was running.',
          style: TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 16),
        const Text('Recent flagged windows',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ]);
      if (flaggedWins.isEmpty) {
        children.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('None in this period.'),
        ));
      } else {
        for (final w in flaggedWins.reversed.take(8)) {
          children.add(ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${_hms(w.ts)}  score '
                '${(w.score ?? 0).toStringAsFixed(2)}'),
            subtitle: Text('${_screenLabel(w.screen)}, '
                'accel ${(w.accel ?? 0).toStringAsFixed(2)}, '
                'gyro ${(w.gyro ?? 0).toStringAsFixed(2)}'),
          ));
        }
      }
    }

    children.add(const SizedBox(height: 16));
    children.add(const Text('Recent sessions',
        style: TextStyle(fontWeight: FontWeight.bold)));
    if (_sessions.isEmpty) {
      children.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No sessions yet.'),
      ));
    }
    for (final s in _sessions) {
      final st = DateTime.tryParse('${s['started_at']}')?.toLocal();
      final enRaw = s['ended_at'];
      final en = enRaw == null ? null : DateTime.tryParse('$enRaw')?.toLocal();
      final dur = (st != null && en != null) ? _dur(en.difference(st)) : null;
      final windows = ((s['windows'] as num?) ?? 0).toInt();
      final fl = ((s['flagged'] as num?) ?? 0).toInt();
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('${_dm(st)} · ${dur ?? 'running or ended unexpectedly'} · '
            '$windows windows · $fl flagged'),
      ));
    }

    children.add(const SizedBox(height: 16));
    children.add(Card(
      child: ListTile(
        title: const Text('Hourly usage insights and today\'s prediction'),
        subtitle: const Text('Open App usage'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const UsageSummaryScreen()),
        ),
      ),
    ));

    return Scaffold(
      appBar: AppBar(title: const Text('Results')),
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

class _ScorePainter extends CustomPainter {
  static const double leftAxis = 36;
  static const double topPad = 10;
  static const double bottomAxis = 24;

  final List<_Bucket> buckets;
  final int? selected;
  final Color barColor;
  final Color flagColor;
  final Color gridColor;
  final Color textColor;
  final Color mutedColor;

  const _ScorePainter({
    required this.buckets,
    required this.selected,
    required this.barColor,
    required this.flagColor,
    required this.gridColor,
    required this.textColor,
    required this.mutedColor,
  });

  void _text(Canvas canvas, String s, Offset pos,
      {double ax = 0.5, double ay = 0.0}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: textColor, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width * ax, pos.dy - tp.height * ay));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final n = buckets.length;
    if (n == 0) return;
    final chartW = size.width - leftAxis;
    final chartH = size.height - topPad - bottomAxis;
    final cellW = chartW / n;
    final baseY = topPad + chartH;
    double yOf(double v) => baseY - v * chartH;
    final sel = selected;

    if (sel != null) {
      canvas.drawRect(
        Rect.fromLTWH(leftAxis + sel * cellW, topPad, cellW, chartH),
        Paint()..color = textColor.withValues(alpha: 0.10),
      );
    }

    final grid = Paint()..strokeWidth = 1;
    for (final v in const [0.0, 0.5, 1.0]) {
      grid.color = v == 0.5
          ? flagColor.withValues(alpha: 0.6)
          : (v == 0.0 ? textColor : gridColor);
      canvas.drawLine(Offset(leftAxis, yOf(v)), Offset(size.width, yOf(v)), grid);
      _text(canvas, v == 0.0 ? '0' : (v == 1.0 ? '1' : '0.5'),
          Offset(leftAxis - 6, yOf(v)),
          ax: 1, ay: 0.5);
    }

    for (var i = 0; i < n; i++) {
      final b = buckets[i];
      if (b.count == 0) continue;
      final cx = leftAxis + (i + 0.5) * cellW;
      final barW = cellW * 0.75;
      final isSel = sel == i;
      Color base;
      double h;
      if (b.scored == 0) {
        base = mutedColor;
        h = 3;
      } else {
        base = b.anomalies > 0 ? flagColor : barColor;
        h = b.maxScore * chartH;
        if (h < 2) h = 2;
      }
      final color = sel == null || isSel ? base : base.withValues(alpha: 0.35);
      final rect = Rect.fromLTWH(cx - barW / 2, baseY - h, barW, h);
      canvas.drawRect(rect, Paint()..color = color);
      if (isSel) {
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = textColor,
        );
      }
    }

    // Time labels sit exactly on the bar edges they describe.
    final tick = Paint()
      ..color = textColor
      ..strokeWidth = 1;
    for (final i in [0, n ~/ 4, n ~/ 2, (3 * n) ~/ 4, n]) {
      final x = leftAxis + i * cellW;
      canvas.drawLine(Offset(x, baseY), Offset(x, baseY + 5), tick);
      final t = i < n ? buckets[i].start : buckets[n - 1].end;
      _text(canvas, _hm(t), Offset(x, baseY + 7));
    }
  }

  @override
  bool shouldRepaint(covariant _ScorePainter old) => true;
}