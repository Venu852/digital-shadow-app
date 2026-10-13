import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ShadowTaskHandler());
}

class ShadowTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('ShadowTask started $timestamp');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    debugPrint('heartbeat $timestamp');
    FlutterForegroundTask.sendDataToMain(
        {'heartbeat': timestamp.millisecondsSinceEpoch});
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('ShadowTask destroyed');
  }
}