import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:test_app/service/task_handler.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/ui/usage_test_screen.dart';
import 'package:test_app/service/usage_sync.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const DigitalShadowApp());
}

class DigitalShadowApp extends StatelessWidget {
  const DigitalShadowApp({super.key});

  @override
  Widget build(BuildContext context) =>
      const MaterialApp(home: HomeScreen());
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _running = false;
  int _heartbeats = 0;
  int _windows = 0;
  String _lastWindow = '-';
  String _accelMean = '-';
  String _gyroMean = '-';
  String _accelCount = '-';
  int _stored = 0;

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
      });
      _refreshStored();
    }
  }

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onData);
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
      ),
    );
    FlutterForegroundTask.isRunningService.then((v) {
      if (mounted) setState(() => _running = v);
    });
    _refreshStored();
    UsageSync.syncRecentDays().catchError((_) => 0);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    super.dispose();
  }

  Future<void> _start() async {
    await FlutterForegroundTask.requestNotificationPermission();
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Digital Shadow session active',
      notificationText: 'Collecting in the background',
      serviceTypes: [ForegroundServiceTypes.specialUse],
      callback: startCallback,
    );
    setState(() => _running = true);
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Digital Shadow')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_running ? 'Session running' : 'Idle'),
            Text('Heartbeats received: $_heartbeats'),
            const SizedBox(height: 16),
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Windows this session: $_windows'),
                    Text('Last window: $_lastWindow'),
                    Text('Accel magnitude mean: $_accelMean'),
                    Text('Gyro magnitude mean: $_gyroMean'),
                    Text('Accel samples (last window): $_accelCount'),
                    Text('Stored windows on device: $_stored'),
                  ],
                ),
              ),
            ),
            ElevatedButton(
              onPressed: _running ? _stop : _start,
              child: Text(_running ? 'Stop session' : 'Start session'),
            ),
            TextButton(
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Delete all data?'),
                    content: const Text(
                        'This removes every stored window on this phone.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true) {
                  await ShadowDb.deleteAll();
                  _refreshStored();
                }
              },
              child: const Text('Delete all data'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UsageTestScreen()),
              ),
              child: const Text('App usage (test)'),
            ),
          ],
        ),
      ),
    );
  }
}