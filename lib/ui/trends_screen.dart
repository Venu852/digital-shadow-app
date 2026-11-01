import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/ui/recap_model.dart';
import 'package:test_app/ui/results_screen.dart';
import 'package:test_app/ui/suggestions_screen.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/today_model.dart';

/// Days read for the chart's longest range and the recap's two weeks.
const int trendsHistoryDays = 30;

const List<int> trendRanges = [14, 30];

/// The dashed line on the chart.
const int elevatedFrom = 45;

/// "31 Oct".
String _shortDate(String day) => formatDay(day).substring(4);

class TrendPoint {
  /// Position in the range: 0 is the oldest day.
  final int index;
  final String day;
  final int drift;

  const TrendPoint(this.index, this.day, this.drift);
}

/// Scored days of the [range] completed days ending at [lastDay], oldest
/// first. [days] may be in any order.
List<TrendPoint> trendPoints(List<DayDrift> days, String lastDay, int range) {
  final byDay = {
    for (final d in days)
      if (d.established) d.day: d.drift!,
  };
  return [
    for (var i = 0; i < range; i++)
      if (byDay[addDays(lastDay, i - range + 1)] != null)
        TrendPoint(
          i,
          addDays(lastDay, i - range + 1),
          byDay[addDays(lastDay, i - range + 1)]!,
        ),
  ];
}

class TrendsScreen extends StatefulWidget {
  /// Changes when the shell shows another tab; the screen reloads on visit.
  final ValueNotifier<int>? tab;
  final int index;

  const TrendsScreen({super.key, this.tab, this.index = 1});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  int _range = trendRanges.first;
  bool _loaded = false;
  List<DayDrift> _days = const [];
  Map<String, int> _checkins = const {};
  int? _selected;
  int _reload = 0;

  @override
  void initState() {
    super.initState();
    widget.tab?.addListener(_onTab);
    DemoMode.enabled.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.tab?.removeListener(_onTab);
    DemoMode.enabled.removeListener(_load);
    super.dispose();
  }

  void _onTab() {
    if (widget.tab?.value == widget.index) _load();
  }

  String get _yesterday => addDays(UsageSync.dayKey(DateTime.now()), -1);

  Future<void> _load() async {
    try {
      final repo = DemoMode.repository;
      final last = _yesterday;
      final from = addDays(last, -(trendsHistoryDays - 1));
      final days = await repo.driftDays(from, last);
      final checkins = await repo.checkins(from, last);
      if (mounted) {
        setState(() {
          _days = days;
          _checkins = checkins;
          _selected = null;
          _loaded = true;
          _reload++;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Widget _card(List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  Widget _title(String t) => Text(
    t,
    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
  );

  Widget _bandLabel(DriftBand band) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.only(right: 6),
        decoration: BoxDecoration(
          color: ShadowColors.bands[band],
          shape: BoxShape.circle,
        ),
      ),
      Text(band.label, style: const TextStyle(fontWeight: FontWeight.w600)),
    ],
  );

  Widget _header(DayDrift latest) {
    final band = driftBand(latest.drift!);
    return _card([
      Row(
        children: [
          Text(
            '${latest.drift}',
            style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _bandLabel(band),
                Text(
                  'Latest drift, ${formatDay(latest.day)}',
                  style: const TextStyle(color: ShadowColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    ]);
  }

  void _selectAt(double dx, double width, List<TrendPoint> points) {
    if (points.isEmpty) return;
    final xs = DriftTrendPainter.xsFor(points, _range, width);
    var best = 0;
    for (var i = 1; i < xs.length; i++) {
      if ((xs[i] - dx).abs() < (xs[best] - dx).abs()) best = i;
    }
    setState(() => _selected = best);
  }

  Widget _chart(List<TrendPoint> points) {
    final sel = _selected;
    final p = sel == null || sel >= points.length ? null : points[sel];
    return _card([
      _title('Drift over $_range days'),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: [
          for (final r in trendRanges)
            ButtonSegment(value: r, label: Text('$r days')),
        ],
        selected: {_range},
        onSelectionChanged: (s) => setState(() {
          _range = s.first;
          _selected = null;
        }),
      ),
      const SizedBox(height: 8),
      Text(
        p == null
            ? 'Tap or drag across the chart to see a day.'
            : '${formatDay(p.day)}: drift ${p.drift}, '
                  '${driftBand(p.drift).label}',
        style: TextStyle(
          color: p == null ? ShadowColors.textSecondary : ShadowColors.text,
          fontWeight: p == null ? FontWeight.normal : FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _selectAt(d.localPosition.dx, w, points),
            onHorizontalDragUpdate: (d) =>
                _selectAt(d.localPosition.dx, w, points),
            child: CustomPaint(
              size: Size(w, 200),
              painter: DriftTrendPainter(
                points: points,
                range: _range,
                selected: p == null ? null : sel,
              ),
            ),
          );
        },
      ),
      if (points.length < 2)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'A line appears once two days in this range are scored.',
            style: TextStyle(color: ShadowColors.textSecondary),
          ),
        ),
    ]);
  }

  Widget _radar(DayDrift d) => _card([
    _title('Signals on ${formatDay(d.day)}'),
    const Text(
      'Each signal\'s level. The inner ring at 12 is an ordinary day for you.',
      style: TextStyle(color: ShadowColors.textSecondary),
    ),
    const SizedBox(height: 8),
    SizedBox(
      height: 280,
      width: double.infinity,
      child: CustomPaint(painter: SignalRadarPainter(levels: d.reportedLevels)),
    ),
  ]);

  Widget _recap() {
    final r = buildRecap(_days, _checkins);
    return _card([
      _title('Your week'),
      const SizedBox(height: 8),
      if (r == null)
        const Text(
          'The weekly recap appears once 7 days have been scored.',
          style: TextStyle(color: ShadowColors.textSecondary),
        )
      else
        for (final s in r.sentences)
          Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(s)),
    ]);
  }

  Widget _motion() {
    if (DemoMode.on) {
      return _card([
        _title('Motion and sessions'),
        const SizedBox(height: 6),
        const Text(
          'Hidden in demo mode, because it shows data stored on this phone.',
          style: TextStyle(color: ShadowColors.textSecondary),
        ),
      ]);
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: _title('Motion and sessions'),
          subtitle: const Text(
            'Motion windows, sessions, the daily list and check-ins',
            style: TextStyle(color: ShadowColors.textSecondary),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: const [ResultsScreen(embedded: true)],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scored = _days.where((d) => d.established).toList()
      ..sort((a, b) => b.day.compareTo(a.day));
    final children = <Widget>[];
    if (!_loaded) {
      children.add(const Center(child: CircularProgressIndicator()));
    } else if (scored.isEmpty) {
      children.add(
        _card([
          _title('No scored days yet'),
          const SizedBox(height: 8),
          const Text(
            'Trends appear once your own baseline exists and completed days '
            'are scored. Keep using your phone as usual.',
          ),
        ]),
      );
    } else {
      final latest = scored.first;
      children.addAll([
        _header(latest),
        _chart(trendPoints(_days, _yesterday, _range)),
        _radar(latest),
        _recap(),
      ]);
    }
    if (_loaded) {
      children.addAll([
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: _title('Suggestions'),
        ),
        SuggestionsPanel(key: ValueKey(_reload)),
        _motion(),
      ]);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Trends')),
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

/// Drift per day: gridlines at 0-100, a dashed line at 45, a point per
/// scored day with the last one ringed, and three date labels.
class DriftTrendPainter extends CustomPainter {
  static const double leftAxis = 30;
  static const double rightPad = 24;
  static const double topPad = 16;
  static const double bottomAxis = 22;

  final List<TrendPoint> points;
  final int range;
  final int? selected;

  const DriftTrendPainter({
    required this.points,
    required this.range,
    this.selected,
  });

  static double xOf(int index, int range, double width) {
    final span = width - leftAxis - rightPad;
    return range <= 1
        ? leftAxis + span / 2
        : leftAxis + span * index / (range - 1);
  }

  static List<double> xsFor(List<TrendPoint> points, int range, double width) =>
      [for (final p in points) xOf(p.index, range, width)];

  void _text(
    Canvas canvas,
    String s,
    Offset pos, {
    double ax = 0.5,
    double ay = 0,
    Color color = ShadowColors.textSecondary,
    double maxX = double.infinity,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = math.min(pos.dx - tp.width * ax, maxX - tp.width);
    tp.paint(canvas, Offset(math.max(0, x), pos.dy - tp.height * ay));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chartH = size.height - topPad - bottomAxis;
    double yOf(num v) => topPad + chartH * (1 - v.clamp(0, 100) / 100);

    final grid = Paint()
      ..color = ShadowColors.border
      ..strokeWidth = 1;
    for (final v in const [0, 25, 50, 75, 100]) {
      canvas.drawLine(
        Offset(leftAxis, yOf(v)),
        Offset(size.width - rightPad, yOf(v)),
        grid,
      );
      _text(canvas, '$v', Offset(leftAxis - 6, yOf(v)), ax: 1, ay: 0.5);
    }

    final dash = Paint()
      ..color = ShadowColors.amber
      ..strokeWidth = 1.5;
    final y45 = yOf(elevatedFrom);
    for (var x = leftAxis; x < size.width - rightPad; x += 8) {
      canvas.drawLine(
        Offset(x, y45),
        Offset(math.min(x + 4, size.width - rightPad), y45),
        dash,
      );
    }
    _text(
      canvas,
      'elevated from $elevatedFrom',
      Offset(size.width - rightPad, y45 - 2),
      ax: 1,
      ay: 1,
      color: ShadowColors.amberText,
      maxX: size.width,
    );

    if (points.isEmpty) return;
    final xs = xsFor(points, range, size.width);
    final sel = selected;
    if (sel != null) {
      canvas.drawLine(
        Offset(xs[sel], topPad),
        Offset(xs[sel], topPad + chartH),
        Paint()
          ..color = ShadowColors.textSecondary
          ..strokeWidth = 1,
      );
    }
    if (points.length > 1) {
      final path = Path()..moveTo(xs[0], yOf(points[0].drift));
      for (var i = 1; i < points.length; i++) {
        path.lineTo(xs[i], yOf(points[i].drift));
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ShadowColors.primary,
      );
    }
    for (var i = 0; i < points.length; i++) {
      final c = Offset(xs[i], yOf(points[i].drift));
      canvas.drawCircle(
        c,
        i == sel ? 5 : 3.5,
        Paint()..color = ShadowColors.bands[driftBand(points[i].drift)]!,
      );
    }
    final last = points.length - 1;
    canvas.drawCircle(
      Offset(xs[last], yOf(points[last].drift)),
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ShadowColors.text,
    );

    final labelled = {0, last ~/ 2, last};
    for (final i in labelled) {
      _text(
        canvas,
        _shortDate(points[i].day),
        Offset(xs[i], topPad + chartH + 6),
        maxX: size.width,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DriftTrendPainter old) =>
      old.points != points || old.range != range || old.selected != selected;
}

/// The six levels on six axes (0-100) against a ring at the neutral 12.
class SignalRadarPainter extends CustomPainter {
  /// Room left for the labels outside the axes.
  static const double labelWidth = 68;
  static const double labelHeight = 34;

  final Map<String, int> levels;

  const SignalRadarPainter({required this.levels});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = math.min(
      size.height / 2 - labelHeight,
      size.width / 2 - labelWidth - 6,
    );
    if (r <= 0) return;
    final n = signalKeys.length;
    double angle(int i) => -math.pi / 2 + 2 * math.pi * i / n;
    Offset at(int i, num v) =>
        center +
        Offset(math.cos(angle(i)), math.sin(angle(i))) *
            (r * v.clamp(0, 100) / 100);

    Path ring(num v) {
      final p = Path()..moveTo(at(0, v).dx, at(0, v).dy);
      for (var i = 1; i < n; i++) {
        p.lineTo(at(i, v).dx, at(i, v).dy);
      }
      return p..close();
    }

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = ShadowColors.border;
    for (final v in const [25, 50, 75, 100]) {
      canvas.drawPath(ring(v), grid);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(center, at(i, 100), grid);
    }
    canvas.drawPath(
      ring(neutralLevel),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = ShadowColors.textSecondary,
    );

    final shape = Path();
    for (var i = 0; i < n; i++) {
      final p = at(i, levels[signalKeys[i]] ?? neutralLevel);
      i == 0 ? shape.moveTo(p.dx, p.dy) : shape.lineTo(p.dx, p.dy);
    }
    shape.close();
    canvas.drawPath(
      shape,
      Paint()..color = ShadowColors.primary.withValues(alpha: 0.25),
    );
    canvas.drawPath(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ShadowColors.primary,
    );

    for (var i = 0; i < n; i++) {
      final k = signalKeys[i];
      final tp = TextPainter(
        text: TextSpan(
          text: '${signalNames[k]}\n${levels[k] ?? neutralLevel}',
          style: const TextStyle(color: ShadowColors.text, fontSize: 11),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: labelWidth);
      final dir = Offset(math.cos(angle(i)), math.sin(angle(i)));
      final anchor = center + dir * (r + 6);
      // Push the label away from the axis end along its direction.
      final dx = dir.dx > 0.3
          ? 0.0
          : (dir.dx < -0.3 ? -tp.width : -tp.width / 2);
      final dy = dir.dy > 0.3
          ? 0.0
          : (dir.dy < -0.3 ? -tp.height : -tp.height / 2);
      tp.paint(canvas, anchor + Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(covariant SignalRadarPainter old) => old.levels != levels;
}
