import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_runner.dart';
import 'package:test_app/service/task_handler.dart';
import 'package:test_app/service/usage_model.dart';
import 'package:test_app/service/usage_reader.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/suggest/suggestion_service.dart';
import 'package:test_app/sync/sync_service.dart';
import 'package:test_app/ui/sharing.dart';
import 'package:test_app/ui/suggestions_screen.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/today_model.dart';

String _fmtMs(int ms) {
  final m = (ms / 60000).round();
  if (m < 60) return '${m}m';
  return '${m ~/ 60}h ${m % 60}m';
}

String _elapsed(Duration d) {
  final m = d.inMinutes;
  if (m < 60) return '$m min';
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

String _hourLabel(int h) {
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12${h < 12 ? 'am' : 'pm'}';
}

String _hourRange(int h) => '${_hourLabel(h)}–${_hourLabel((h + 1) % 24)}';

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
    case 'notifs':
      return 'Notifications seen';
    default:
      return f;
  }
}

String _featVal(String f, double v) {
  if (f == 'fgMin' || f == 'screenMin') return _fmtMs((v * 60000).round());
  return v.round().toString();
}

String _featExp(String f, double v) {
  if (f == 'fgMin' || f == 'screenMin') return _fmtMs((v * 60000).round());
  return v.toStringAsFixed(1);
}

class TodayScreen extends StatefulWidget {
  /// Changes when the shell shows another tab; the screen reloads on visit.
  final ValueNotifier<int>? tab;
  final int index;

  const TodayScreen({super.key, this.tab, this.index = 0});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> with WidgetsBindingObserver {
  // Session (moved from the old home screen, behaviour unchanged).
  bool _running = false;
  int _heartbeats = 0;
  int _windows = 0;
  String _lastWindow = '-';
  String _accelMean = '-';
  String _gyroMean = '-';
  String _accelCount = '-';
  int _stored = 0;
  String _modelStatus = 'Model: waiting for first window';
  DateTime? _sessionStart;
  Timer? _ticker;

  // Today's view.
  TodayModel? _model;
  SharingState _sharing = const SharingState('nothing');
  List<DataBanner> _banners = const [];
  Map<String, int> _behavior = const {};
  UsageInsights? _insights;
  SuggestionView? _suggestions;

  String _fmt(Object? v) => v is num ? v.toStringAsFixed(3) : '-';

  Future<void> _refreshStored() async {
    try {
      final n = await ShadowDb.countWindows();
      if (mounted) setState(() => _stored = n);
    } catch (_) {}
  }

  void _onData(Object data) {
    if (data is! Map) return;
    if (data.containsKey('heartbeat')) {
      setState(() => _heartbeats++);
    }
    final w = data['window'];
    if (w is Map) {
      setState(() {
        _windows++;
        _lastWindow = '${w['window_end_ts'] ?? '-'}';
        _accelMean = _fmt(w['accel_mag_mean']);
        _gyroMean = _fmt(w['gyro_mag_mean']);
        _accelCount = '${w['sample_count_accel'] ?? '-'}';
        final calib = w['calibrating'] == true;
        final seen = w['windows_seen'] ?? 0;
        final score = w['score'];
        if (calib) {
          _modelStatus = 'Model: on-device, calibrating $seen/20';
        } else if (score is num) {
          _modelStatus =
              'Model: on-device, anomaly score ${score.toStringAsFixed(2)}'
              '${w['is_anomaly'] == true ? ' (ANOMALY)' : ''}';
        } else {
          _modelStatus = 'Model: on-device, no score';
        }
      });
      _refreshStored();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tab?.addListener(_onTab);
    DemoMode.enabled.addListener(_load);
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _initService();
    FlutterForegroundTask.isRunningService.then((v) {
      if (mounted) setState(() => _running = v);
      _loadSession();
    });
    _refreshStored();
    _load();
    UsageSync.syncRecentDays()
        .catchError((_) => 0)
        .then((_) => DriftRunner.instance.run())
        .catchError((_) => const SyncResult(SyncState.stopped))
        .whenComplete(_load);
    ShadowDb.getSetting('retention_days')
        .then((v) => ShadowDb.applyRetention(int.tryParse(v ?? '') ?? 30))
        .catchError((_) {});
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _running) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.tab?.removeListener(_onTab);
    DemoMode.enabled.removeListener(_load);
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  void _onTab() {
    if (widget.tab?.value == widget.index) _load();
  }

  /// When the running session began: its open sessions row, else the last
  /// time Start was pressed.
  Future<void> _loadSession() async {
    try {
      DateTime? start;
      if (_running) {
        final rows = await ShadowDb.recentSessions(1);
        if (rows.isNotEmpty && rows.first['ended_at'] == null) {
          start = DateTime.tryParse('${rows.first['started_at']}')?.toLocal();
        }
        if (start == null) {
          final ms = int.tryParse(
              await ShadowDb.getSetting('last_manual_start') ?? '');
          if (ms != null) start = DateTime.fromMillisecondsSinceEpoch(ms);
        }
      }
      if (mounted) setState(() => _sessionStart = start);
    } catch (_) {
      // Elapsed time is left out.
    }
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final today = UsageSync.dayKey(now);
    final yesterday = addDays(today, -1);
    try {
      final repo = DemoMode.repository;
      final rows = await repo.driftDays(
          addDays(today, -DriftRunner.days), yesterday);
      final dataDays = await repo.dataDays(
          addDays(yesterday, -(baselineWindowDays - 1)), yesterday);
      final ctx = await ShadowDb.getSetting(personalContextKey);
      final model =
          buildTodayModel(rows, dataDays: dataDays, context: ctx);
      if (mounted) setState(() => _model = model);
    } catch (_) {
      // The drift card keeps its last state.
    }
    try {
      final view = await loadSuggestionView();
      if (mounted) setState(() => _suggestions = view);
    } catch (_) {
      // The suggestions card keeps its last state.
    }
    try {
      final sharing = await SharingControl.instance.load();
      final access = await UsageReader.hasAccess();
      final paired = await SyncService.instance.isPaired();
      final status = await ShadowDb.getSetting('sync_status');
      final days = await ShadowDb.usageDaySummaries();
      final sessions = await ShadowDb.recentSessions(1);
      final last = sessions.isEmpty ? null : sessions.first;
      final banners = bannersFor(BannerState(
        now: now,
        usageAccess: access,
        signedOut: paired && status == SyncStatus.signedOut,
        sharingPausedSince: sharing.pausedSince,
        lastUsageDay: days.isEmpty ? null : '${days.first['day']}',
        lastSessionStart: last == null
            ? null
            : DateTime.tryParse('${last['started_at']}'),
        lastSessionEnded: last == null || last['ended_at'] != null,
        sessionRunning: _running,
      ));
      if (mounted) {
        setState(() {
          _sharing = sharing;
          _banners = banners;
        });
      }
    } catch (_) {
      // Banners and the sharing chip keep their last state.
    }
    try {
      final from = UsageSync.dayKey(DateTime(now.year, now.month, now.day - 6));
      final behavior = await ShadowDb.behaviorTotals(today, today);
      final insights = analyzeUsage(
        behaviorRows: await ShadowDb.behaviorRows(from, today),
        fgRows: await ShadowDb.hourlyForeground(from, today),
        now: now,
        todayKey: today,
      );
      if (mounted) {
        setState(() {
          _behavior = behavior;
          _insights = insights;
        });
      }
    } catch (_) {
      // The usage cards stay empty.
    }
  }

  /// Returns true to continue starting the session.
  Future<bool> _maybeBatteryHint() async {
    try {
      final shown = await ShadowDb.getSetting('battery_hint_shown');
      if (shown == '1' || !mounted) return true;
      await ShadowDb.setSetting('battery_hint_shown', '1');
      if (!mounted) return true;
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Keep the session running'),
          content: const Text(
              'To keep collecting while the screen is off, set this app to '
              '"Unrestricted" or "Don\'t optimise" in the battery settings. '
              'You can also do this later in Privacy.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open battery settings')),
          ],
        ),
      );
      if (open == true) {
        await UsageReader.openBatterySettings();
        return false; // Tap Start again after coming back.
      }
    } catch (_) {
      // Never block starting because of the hint.
    }
    return true;
  }

  Future<void> _initService() async {
    var autoRestart = false;
    try {
      autoRestart = (await ShadowDb.getSetting('auto_restart')) == '1';
    } catch (_) {
      // Default to off.
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'digital_shadow',
        channelName: 'Digital Shadow session',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        allowWakeLock: true,
        autoRunOnBoot: autoRestart,
      ),
    );
  }

  Future<void> _start() async {
    if (!await _maybeBatteryHint()) return;
    await FlutterForegroundTask.requestNotificationPermission();
    await _initService();
    final started = DateTime.now();
    try {
      await ShadowDb.setSetting(
          'last_manual_start', '${started.millisecondsSinceEpoch}');
    } catch (_) {
      // Not critical.
    }
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Digital Shadow session active',
      notificationText: 'Collecting in the background',
      serviceTypes: [ForegroundServiceTypes.specialUse],
      callback: startCallback,
    );
    setState(() {
      _running = true;
      _sessionStart = started;
    });
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
    setState(() {
      _running = false;
      _sessionStart = null;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _bannerAction(DataBanner b) async {
    switch (b.kind) {
      case BannerKind.usageAccess:
        await UsageReader.openSettings();
      case BannerKind.sharingPaused:
        final error = await SharingControl.instance.resume();
        _snack(error ?? 'Sharing resumed.');
        await _load();
      case BannerKind.sessionEnded:
        await UsageReader.openBatterySettings();
      case BannerKind.signedOut:
      case BannerKind.usageStale:
        break;
    }
  }

  TextStyle get _secondary => const TextStyle(color: ShadowColors.textSecondary);

  Widget _title(String t) => Text(t,
      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16));

  Widget _card(List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children),
        ),
      );

  Widget _bannerTile(DataBanner b) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: ShadowColors.amber),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: ShadowColors.amberText),
              const SizedBox(width: 12),
              Expanded(child: Text(b.text)),
              if (b.action != null)
                TextButton(
                    onPressed: () => _bannerAction(b), child: Text(b.action!)),
            ],
          ),
        ),
      );

  Widget _sessionCard() {
    final start = _sessionStart;
    return _card([
      Row(
        children: [
          Expanded(child: _title(_running ? 'Session running' : 'Idle')),
          FilledButton(
            onPressed: _running ? _stop : (DemoMode.on ? null : _start),
            child: Text(_running ? 'Stop session' : 'Start session'),
          ),
        ],
      ),
      if (!_running && DemoMode.on)
        Text('Sessions do not start in demo mode.', style: _secondary),
      if (_running && start != null)
        Text('Running for ${_elapsed(DateTime.now().difference(start))}',
            style: _secondary),
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Session details', style: _secondary),
          children: [
            for (final t in [
              'Heartbeats received: $_heartbeats',
              'Windows this session: $_windows',
              'Last window: $_lastWindow',
              'Accel magnitude mean: $_accelMean',
              'Gyro magnitude mean: $_gyroMean',
              'Accel samples (last window): $_accelCount',
              'Stored windows on device: $_stored',
              _modelStatus,
            ])
              Align(alignment: Alignment.centerLeft, child: Text(t)),
          ],
        ),
      ),
    ]);
  }

  Widget _driftCard(TodayModel m) {
    if (m.calibrating) {
      return _card([
        _title('Learning your usual'),
        const SizedBox(height: 8),
        Text(m.calibrationText),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: m.calibrationDay / minBaselineDays,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 8),
        Text('Drift is scored only for completed days.', style: _secondary),
      ]);
    }
    final band = m.band!;
    final color = ShadowColors.bands[band]!;
    return _card([
      Row(
        children: [
          SizedBox(
            width: 132,
            height: 132,
            child: CustomPaint(
              painter: DriftRingPainter(value: m.shownDrift!, color: color),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${m.shownDrift}',
                        style: const TextStyle(
                            fontSize: 36, fontWeight: FontWeight.bold)),
                    Text('drift', style: _secondary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 6),
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    Text(band.label,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(m.bandSentence!),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(m.asOfText!),
      Text('Confidence ${m.confidence}%, ${m.observedText}', style: _secondary),
      Text('Baseline: Established', style: _secondary),
      if (m.contextLine != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(m.contextLine!),
        ),
      const SizedBox(height: 6),
      Text('Today\'s reading arrives tomorrow.', style: _secondary),
    ]);
  }

  Widget _tile(String label, String value) => Expanded(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(label, style: _secondary),
              ],
            ),
          ),
        ),
      );

  Widget _glance() {
    final b = _behavior;
    final unlocks = b['unlocks'] ?? 0;
    final checks = unlocks > 0 ? unlocks : (b['wakeups'] ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title('Today at a glance'),
        const SizedBox(height: 8),
        Row(
          children: [
            _tile('Screen on time', _fmtMs(b['screen_ms'] ?? 0)),
            _tile('Phone checks', '$checks'),
            _tile('Notifications seen', '${b['notifications'] ?? 0}'),
          ],
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _predicted(UsageInsights ins) {
    if (!ins.ready) {
      return _card([
        _title('Predicted for today'),
        const SizedBox(height: 8),
        Text('Learning your usual patterns: ${ins.baselineDays} of '
            '$kMinBaselineDays earlier days available.'),
      ]);
    }
    return _card([
      _title('Predicted for today'),
      Text('So far, plus your usual for the rest of the day', style: _secondary),
      const SizedBox(height: 8),
      for (final f in const ['pickups', 'opens', 'fgMin', 'screenMin', 'notifs'])
        if (ins.forecasts[f] != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Builder(builder: (context) {
              final fc = ins.forecasts[f]!;
              final above = fc.total > fc.usualTotal;
              return Text(
                '${_featLabel(f, ins.unlocksReported)}: '
                '${_featVal(f, fc.total)} (usual day '
                '${_featVal(f, fc.usualTotal)}, so far '
                '${_featVal(f, fc.actualSoFar)})'
                '${above ? ', above your usual' : ''}',
                style: above
                    ? const TextStyle(color: ShadowColors.amberText)
                    : null,
              );
            }),
          ),
    ]);
  }

  Widget _unusual(UsageInsights ins) => _card([
        _title('Unusual today'),
        const SizedBox(height: 8),
        if (!ins.ready)
          const Text('Not enough earlier days to compare yet.')
        else if (ins.flagsToday.isEmpty)
          const Text('None so far today.')
        else
          for (final fl in ins.flagsToday.take(6))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${_hourRange(fl.sample.hour)}: '
                  '${_featLabel(fl.topFeature, ins.unlocksReported)} '
                  '${_featVal(fl.topFeature, fl.sample.f[fl.topFeature] ?? 0)} '
                  '(usual ~${_featExp(fl.topFeature, fl.expected)}), '
                  'unusually ${fl.topZ > 0 ? 'high' : 'low'}'),
            ),
        const SizedBox(height: 8),
        Text('Unusual means different from your own pattern. It does not '
            'mean harmful.', style: _secondary),
      ]);

  @override
  Widget build(BuildContext context) {
    final m = _model;
    final ins = _insights;
    return Scaffold(
      appBar: AppBar(title: const Text('Today')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            for (final b in _banners) _bannerTile(b),
            Align(alignment: Alignment.centerLeft, child: SharingChip(_sharing)),
            const SizedBox(height: 8),
            _sessionCard(),
            if (m != null) ...[
              _driftCard(m),
              _card([
                _title('If the trend continues'),
                const SizedBox(height: 6),
                Text(m.horizon),
              ]),
            ],
            if (_suggestions != null)
              SuggestionsSummaryCard(view: _suggestions!, onReturn: _load),
            // Usage from this phone is left out while the drift is simulated.
            if (!DemoMode.on) _glance(),
            if (!DemoMode.on && ins != null && ins.dataDays > 0) ...[
              _predicted(ins),
              _unusual(ins),
            ],
          ],
        ),
      ),
    );
  }
}

/// A 132 px ring: a full track and an arc for [value] out of 100.
class DriftRingPainter extends CustomPainter {
  final int value;
  final Color color;

  const DriftRingPainter({required this.value, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: math.min(size.width, size.height) / 2 - stroke / 2);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = ShadowColors.border;
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);
    final sweep = 2 * math.pi * value.clamp(0, 100) / 100;
    if (sweep <= 0) return;
    canvas.drawArc(
        rect,
        -math.pi / 2,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round
          ..color = color);
  }

  @override
  bool shouldRepaint(covariant DriftRingPainter old) =>
      old.value != value || old.color != color;
}
