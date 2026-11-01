import 'package:test_app/data/db.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/drift/drift_runner.dart';
import 'package:test_app/service/app_categories.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/suggest/suggestion_builder.dart';

/// Where the screens read drift days, levels and the phone-only totals
/// used by suggestions. The real one reads drift_days; demo mode swaps in
/// simulated data.
abstract class DriftRepository {
  /// True for simulated data.
  bool get simulated;

  /// Drift days between the two days, newest first.
  Future<List<DayDrift>> driftDays(String fromDay, String toDay);

  /// Days between the two days with any stored data.
  Future<int> dataDays(String fromDay, String toDay);

  /// Check-in scores (1-5) by day.
  Future<Map<String, int>> checkins(String fromDay, String toDay);

  /// Daily limits set on this phone.
  Future<List<DailyLimit>> limits();

  /// Late-night minutes and limit usage per day between the two days.
  Future<List<PhoneDay>> phoneDays(
    String fromDay,
    String toDay,
    List<DailyLimit> limits,
  );
}

const String _ownPackage = 'com.example.test_app';
const String _categoryPrefix = 'limit_min_';
const String _appPrefix = 'limit_app_';

class DbDriftRepository implements DriftRepository {
  const DbDriftRepository();

  @override
  bool get simulated => false;

  @override
  Future<List<DayDrift>> driftDays(String fromDay, String toDay) async =>
      (await ShadowDb.driftDays(fromDay, toDay)).map(driftFromRow).toList();

  @override
  Future<int> dataDays(String fromDay, String toDay) async =>
      (await const DbDriftStore().inputs(
        fromDay,
        toDay,
      )).where((r) => r.hasData).length;

  @override
  Future<Map<String, int>> checkins(String fromDay, String toDay) =>
      ShadowDb.checkins(fromDay, toDay);

  @override
  Future<List<DailyLimit>> limits() async {
    final out = <DailyLimit>[];
    for (final c in AppCategory.values) {
      final n = int.tryParse(
        await ShadowDb.getSetting('$_categoryPrefix${c.name}') ?? '',
      );
      if (n != null && n > 0) {
        out.add(DailyLimit('$_categoryPrefix${c.name}', c.label, n));
      }
    }
    final apps = await ShadowDb.getSettingsByPrefix(_appPrefix);
    if (apps.isEmpty) return out;
    final today = UsageSync.dayKey(DateTime.now());
    final labels = {
      for (final m in await ShadowDb.usageTopApps(
        addDays(today, -baselineWindowDays),
        today,
      ))
        '${m['package']}': '${m['label']}',
    };
    final packages = apps.keys.toList()..sort();
    for (final k in packages) {
      final n = int.tryParse(apps[k]!);
      final pkg = k.substring(_appPrefix.length);
      if (n != null && n > 0) out.add(DailyLimit(k, labels[pkg] ?? pkg, n));
    }
    return out;
  }

  @override
  Future<List<PhoneDay>> phoneDays(
    String fromDay,
    String toDay,
    List<DailyLimit> limits,
  ) async {
    final inputs = {
      for (final r in await const DbDriftStore().inputs(fromDay, toDay))
        r.day: r,
    };
    final minutes = <String, Map<String, double>>{};
    for (final m in await ShadowDb.usageRows(fromDay, toDay)) {
      final pkg = '${m['package']}';
      // Like the Usage tab: no system components, not this app.
      if ('${m['label']}' == pkg || pkg == _ownPackage) continue;
      final cat = categoryFor(pkg, ((m['category'] as num?) ?? -1).toInt());
      final day = minutes.putIfAbsent('${m['day']}', () => {});
      final min = ((m['total_ms'] as num?) ?? 0) / 60000;
      for (final key in ['$_categoryPrefix${cat.name}', '$_appPrefix$pkg']) {
        day[key] = (day[key] ?? 0) + min;
      }
    }
    final days = {...inputs.keys, ...minutes.keys}.toList()..sort();
    return [
      for (final d in days)
        PhoneDay(
          day: d,
          hasScreen: (inputs[d]?.screenMs ?? 0) > 0,
          nightMinutes: (inputs[d]?.nightScreenMs ?? 0) / 60000,
          hasUsage: minutes.containsKey(d),
          limitMinutes: {
            for (final l in limits)
              if (minutes[d]?[l.key] != null) l.key: minutes[d]![l.key]!,
          },
        ),
    ];
  }
}
