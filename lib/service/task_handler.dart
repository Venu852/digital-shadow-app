import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/anomaly_model.dart';
import 'package:test_app/service/window_aggregator.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ShadowTaskHandler());
}

// NOTE: all windowing uses DateTime timestamps, never tick counts,
// because repeat events can be delayed while the CPU sleeps.
class ShadowTaskHandler extends TaskHandler {
  final WindowAggregator _agg = WindowAggregator();
  final Battery _battery = Battery();
  StreamSubscription<dynamic>? _accelSub;
  StreamSubscription<dynamic>? _gyroSub;
  int? _batteryStart;
  int _windowCount = 0;
  int? _sessionId;
  AnomalyModel _model = AnomalyModel();

  Future<int?> _readBatteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (e) {
      debugPrint('WARN battery level: $e');
      return null;
    }
  }

  Future<bool?> _readCharging() async {
    try {
      final s = await _battery.batteryState;
      return s == BatteryState.charging || s == BatteryState.full;
    } catch (e) {
      debugPrint('WARN battery state: $e');
      return null;
    }
  }

  Future<String?> _readNetwork() async {
    try {
      final r = await Connectivity().checkConnectivity();
      if (r.contains(ConnectivityResult.wifi)) return 'wifi';
      if (r.contains(ConnectivityResult.mobile)) return 'cellular';
      if (r.contains(ConnectivityResult.ethernet)) return 'ethernet';
      if (r.isEmpty || r.contains(ConnectivityResult.none)) return 'none';
      return 'other';
    } catch (e) {
      debugPrint('WARN network: $e');
      return null;
    }
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('ShadowTask started $timestamp');
    _batteryStart = await _readBatteryLevel();
    _agg.start(timestamp);

    try {
      final keepDays =
          int.tryParse(await ShadowDb.getSetting('retention_days') ?? '') ?? 30;
      await ShadowDb.applyRetention(keepDays);
      _sessionId = await ShadowDb.startSession(timestamp);
    } catch (e) {
      debugPrint('WARN db start: $e');
    }

    try {
      final saved = await ShadowDb.getSetting('motion_baseline');
      if (saved != null && saved.isNotEmpty) {
        _model = AnomalyModel.fromJsonString(saved);
      }
    } catch (e) {
      debugPrint('WARN baseline load: $e');
    }

    try {
      _accelSub = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 50),
      ).listen(
            (e) => _agg.addAccel(e.x, e.y, e.z),
        onError: (Object e) => debugPrint('WARN accel stream: $e'),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('WARN accel subscribe: $e');
    }
    try {
      _gyroSub = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: 50),
      ).listen(
            (e) => _agg.addGyro(e.x, e.y, e.z),
        onError: (Object e) => debugPrint('WARN gyro stream: $e'),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('WARN gyro subscribe: $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    debugPrint('heartbeat $timestamp');
    FlutterForegroundTask.sendDataToMain(
        {'heartbeat': timestamp.millisecondsSinceEpoch});
    _closeWindowIfDue(timestamp);
  }

  Future<void> _closeWindowIfDue(DateTime now) async {
    try {
      final start = _agg.windowStart;
      if (start == null || now.difference(start).inSeconds < 25) return;
      final batteryEnd = await _readBatteryLevel();
      final charging = await _readCharging();
      final network = await _readNetwork();
      final summary = _agg.close(
        now,
        batteryStart: _batteryStart,
        batteryEnd: batteryEnd,
        charging: charging,
        networkType: network,
      );
      _batteryStart = batteryEnd;
      _windowCount++;

      ScoreResult? result;
      try {
        result = _model.process(summary);
        summary['score'] = result.score;
        summary['is_anomaly'] = result.isAnomaly;
        summary['calibrating'] = result.calibrating;
        summary['windows_seen'] = result.windowsSeen;
      } catch (e) {
        debugPrint('WARN model: $e');
      }

      try {
        await ShadowDb.insertWindow(_sessionId, summary,
            score: result?.score,
            isAnomaly: result?.score == null ? null : result!.isAnomaly);
      } catch (e) {
        debugPrint('WARN db insert: $e');
      }

      try {
        await ShadowDb.setSetting('motion_baseline', _model.toJsonString());
      } catch (e) {
        debugPrint('WARN baseline save: $e');
      }

      debugPrint('WINDOW ${jsonEncode(summary)}');
      FlutterForegroundTask.sendDataToMain({'window': summary});
      try {
        await FlutterForegroundTask.saveData(
            key: 'last_window', value: jsonEncode(summary));
        await FlutterForegroundTask.saveData(
            key: 'window_count', value: _windowCount);
      } catch (e) {
        debugPrint('WARN saveData: $e');
      }
    } catch (e) {
      debugPrint('WARN close window: $e');
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _accelSub?.cancel();
    await _gyroSub?.cancel();
    try {
      final id = _sessionId;
      if (id != null) await ShadowDb.endSession(id, timestamp);
    } catch (e) {
      debugPrint('WARN db end: $e');
    }
    debugPrint('ShadowTask destroyed');
  }
}