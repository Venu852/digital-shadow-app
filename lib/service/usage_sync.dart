import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/screen_state.dart';
import 'package:test_app/service/usage_reader.dart';

class UsageSync {
  static bool _running = false;

  /// Event types the phone reported for today, kept for the diagnostics line.
  static Map<String, int> lastTypeCounts = {};

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

  /// Writes the screen state into stored motion windows that don't have it
  /// yet. Returns how many windows were updated.
  static Future<int> _fillWindowScreen(
      DateTime start, DateTime end, List<List<int>> intervals) async {
    final rows = await ShadowDb.windowsBetween(
        start.toUtc().toIso8601String(), end.toUtc().toIso8601String());
    final updates = <MapEntry<int, String>>[];
    final samples = <double>[];
    for (final r in rows) {
      try {
        final id = (r['id'] as num).toInt();
        final json =
        jsonDecode('${r['features_json']}') as Map<String, dynamic>;
        if (json['screen_on_fraction'] != null) continue;
        final ws = DateTime.parse('${json['window_start_ts']}')
            .millisecondsSinceEpoch;
        final we =
            DateTime.parse('${json['window_end_ts']}').millisecondsSinceEpoch;
        final frac = screenFraction(intervals, ws, we);
        json['screen_on_fraction'] = frac;
        updates.add(MapEntry(id, jsonEncode(json)));
        if (samples.length < 4) {
          samples.add(double.parse(frac.toStringAsFixed(2)));
        }
      } catch (_) {
        // Skip a window we can't read.
      }
    }
    if (updates.isNotEmpty) await ShadowDb.updateWindowFeatures(updates);
    debugPrint('SYNC screen fill: ${updates.length} windows, e.g. $samples');
    return updates.length;
  }

  /// Copies the last [days] days of usage (daily, hourly, behaviour counts
  /// and screen-on time) into the database. Days where Android returns
  /// nothing are left untouched, so saved history is never overwritten with
  /// empty data.
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

        List<List<int>> screenIntervals = [];
        try {
          screenIntervals = await UsageReader.queryScreenIntervals(start, end);
        } catch (_) {
          // Screen state is optional.
        }
        final screenHours = screenIntervals.isEmpty
            ? List<int>.filled(24, 0)
            : hourlyScreenMs(screenIntervals, start.millisecondsSinceEpoch);

        try {
          final b = await UsageReader.queryBehaviorHourly(start, end);
          final brows = <Map<String, Object?>>[];
          for (var h = 0; h < 24; h++) {
            final o = h < b.opens.length ? b.opens[h] : 0;
            final s = h < b.switches.length ? b.switches[h] : 0;
            final w = h < b.wakeups.length ? b.wakeups[h] : 0;
            final u = h < b.unlocks.length ? b.unlocks[h] : 0;
            final sc = screenHours[h];
            if (o + s + w + u + sc > 0) {
              brows.add({
                'hour': h,
                'opens': o,
                'switches': s,
                'wakeups': w,
                'unlocks': u,
                'screen_ms': sc,
              });
            }
          }
          if (brows.isNotEmpty) {
            await ShadowDb.replaceBehaviorDay(dayKey(start), brows);
          }
          if (i == 0) lastTypeCounts = b.typeCounts;
        } catch (_) {
          // Behaviour data is optional.
        }

        if (screenIntervals.isNotEmpty) {
          try {
            await _fillWindowScreen(start, end, screenIntervals);
          } catch (_) {
            // Filling stored windows is best effort.
          }
        }
        written++;
      }
      return written;
    } finally {
      _running = false;
    }
  }
}