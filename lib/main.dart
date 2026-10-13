import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:test_app/service/task_handler.dart';

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

  void _onData(Object data) {
    if (data is Map && data.containsKey('heartbeat')) {
      setState(() => _heartbeats++);
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
            ElevatedButton(
              onPressed: _running ? _stop : _start,
              child: Text(_running ? 'Stop session' : 'Start session'),
            ),
          ],
        ),
      ),
    );
  }
}