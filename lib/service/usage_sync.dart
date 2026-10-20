import 'package:test_app/data/db.dart';
import 'package:test_app/service/usage_reader.dart';

class UsageSync {
  static bool _running = false;

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  /// Copies the last [days] days of per-app usage (daily and hourly) into
  /// the database. Days where Android returns nothing are left untouched.
  static Future<int> syncRecentDays({int days = 7}) async {
    if (_running) return 0;
    _running = true;
    try {
      if (!await UsageReader.hasAccess()) return 0;
      final now = DateTime.now();
      var written = 0;
      for (var i = 0; i < days; i++) {
        final start = DateTime(now.year, now.month, now.day - i);
        final end =
        i == 0 ? now : DateTime(now.year, now.month, now.day - i + 1);
        final apps = await UsageReader.query(start, end);
        if (apps.isEmpty) continue;
        final rows = apps
            .map((a) => <String, Object?>{
          'package': a.packageName,
          'label': a.label,
          'total_ms': a.totalMs,
          'sessions': a.sessions,
          'last_used_ms': a.lastUsedMs,
          'category': a.category,
        })
            .toList();
        await ShadowDb.upsertUsageDay(dayKey(start), rows);

        try {
          final hourly = await UsageReader.queryHourly(start, end);
          if (hourly.isNotEmpty) {
            final hrows = <Map<String, Object?>>[];
            for (final a in hourly) {
              for (var h = 0; h < 24 && h < a.hours.length; h++) {
                if (a.hours[h] > 0) {
                  hrows.add({
                    'hour': h,
                    'package': a.packageName,
                    'total_ms': a.hours[h],
                  });
                }
              }
            }
            await ShadowDb.replaceUsageHourly(dayKey(start), hrows);
          }
        } catch (_) {
          // Hourly data is optional; daily totals are already saved.
        }
        written++;
      }
      return written;
    } finally {
      _running = false;
    }
  }
}