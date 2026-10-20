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

class UsageReader {
  static const MethodChannel _ch = MethodChannel('digital_shadow/usage');

  static Future<bool> hasAccess() async =>
      (await _ch.invokeMethod<bool>('hasUsageAccess')) ?? false;

  static Future<void> openSettings() async {
    await _ch.invokeMethod('openUsageAccessSettings');
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
}