import 'package:flutter/services.dart';

class AppUsage {
  final String packageName;
  final String label;
  final int totalMs;
  final int sessions;
  final int lastUsedMs;
  final int category;

  const AppUsage({
    required this.packageName,
    required this.label,
    required this.totalMs,
    required this.sessions,
    required this.lastUsedMs,
    required this.category,
  });

  factory AppUsage.fromMap(Map<dynamic, dynamic> m) => AppUsage(
    packageName: '${m['package']}',
    label: '${m['label']}',
    totalMs: (m['totalMs'] as num).toInt(),
    sessions: (m['sessions'] as num).toInt(),
    lastUsedMs: (m['lastUsedMs'] as num).toInt(),
    category: (m['category'] as num).toInt(),
  );
}

class AppHourly {
  final String packageName;
  final String label;
  final int category;
  final List<int> hours;

  const AppHourly({
    required this.packageName,
    required this.label,
    required this.category,
    required this.hours,
  });

  factory AppHourly.fromMap(Map<dynamic, dynamic> m) => AppHourly(
    packageName: '${m['package']}',
    label: '${m['label']}',
    category: (m['category'] as num).toInt(),
    hours: (m['hours'] as List<dynamic>)
        .map((e) => (e as num).toInt())
        .toList(),
  );
}

class BehaviorHourly {
  final List<int> opens;
  final List<int> switches;
  final List<int> wakeups;
  final List<int> unlocks;
  final List<int> notifications;
  final Map<String, int> typeCounts;

  const BehaviorHourly({
    required this.opens,
    required this.switches,
    required this.wakeups,
    required this.unlocks,
    required this.notifications,
    required this.typeCounts,
  });

  factory BehaviorHourly.fromMap(Map<dynamic, dynamic> m) {
    List<int> ints(dynamic v) => ((v as List<dynamic>?) ?? [])
        .map((e) => (e as num).toInt())
        .toList();
    final tc = <String, int>{};
    ((m['typeCounts'] as Map<dynamic, dynamic>?) ?? {}).forEach((k, v) {
      tc['$k'] = (v as num).toInt();
    });
    return BehaviorHourly(
      opens: ints(m['opens']),
      switches: ints(m['switches']),
      wakeups: ints(m['wakeups']),
      unlocks: ints(m['unlocks']),
      notifications: ints(m['notifications']),
      typeCounts: tc,
    );
  }
}

class UsageReader {
  static const MethodChannel _ch = MethodChannel('digital_shadow/usage');

  static Future<bool> hasAccess() async =>
      (await _ch.invokeMethod<bool>('hasUsageAccess')) ?? false;

  static Future<void> openSettings() async {
    await _ch.invokeMethod('openUsageAccessSettings');
  }

  static Future<void> openBatterySettings() async {
    await _ch.invokeMethod('openBatterySettings');
  }

  static Future<void> openNotificationSettings() async {
    await _ch.invokeMethod('openNotificationSettings');
  }

  static Future<List<AppUsage>> query(DateTime start, DateTime end) async {
    final raw = await _ch.invokeMethod<List<dynamic>>('queryUsage', {
      'startMs': start.millisecondsSinceEpoch,
      'endMs': end.millisecondsSinceEpoch,
    });
    return (raw ?? [])
        .map((e) => AppUsage.fromMap(Map<dynamic, dynamic>.from(e as Map)))
        .toList();
  }
  static Future<List<AppHourly>> queryHourly(
      DateTime start, DateTime end) async {
    final raw = await _ch.invokeMethod<List<dynamic>>('queryHourly', {
      'startMs': start.millisecondsSinceEpoch,
      'endMs': end.millisecondsSinceEpoch,
    });
    return (raw ?? [])
        .map((e) => AppHourly.fromMap(Map<dynamic, dynamic>.from(e as Map)))
        .toList();
  }
  static Future<BehaviorHourly> queryBehaviorHourly(
      DateTime start, DateTime end) async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'queryBehaviorHourly', {
      'startMs': start.millisecondsSinceEpoch,
      'endMs': end.millisecondsSinceEpoch,
    });
    return BehaviorHourly.fromMap(raw ?? <dynamic, dynamic>{});
  }
  static Future<List<List<int>>> queryScreenIntervals(
      DateTime start, DateTime end) async {
    final raw = await _ch.invokeMethod<List<dynamic>>('queryScreenIntervals', {
      'startMs': start.millisecondsSinceEpoch,
      'endMs': end.millisecondsSinceEpoch,
    });
    return (raw ?? [])
        .map((e) =>
        (e as List<dynamic>).map((x) => (x as num).toInt()).toList())
        .toList();
  }
}