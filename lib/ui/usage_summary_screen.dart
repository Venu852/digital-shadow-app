import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/usage_reader.dart';
import 'package:test_app/service/usage_sync.dart';

const String _ownPackage = 'com.example.test_app';

class UsageSummaryScreen extends StatefulWidget {
  const UsageSummaryScreen({super.key});

  @override
  State<UsageSummaryScreen> createState() => _UsageSummaryScreenState();
}

class _UsageSummaryScreenState extends State<UsageSummaryScreen>
    with WidgetsBindingObserver {
  bool _access = false;
  bool _loading = true;
  String _error = '';
  int _days = 1;
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = '';
      });
    }
    try {
      final ok = await UsageReader.hasAccess();
      if (ok) await UsageSync.syncRecentDays(days: _days == 1 ? 1 : 7);
      await _loadRows();
      if (mounted) setState(() => _access = ok);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load usage: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRows() async {
    final now = DateTime.now();
    final to = UsageSync.dayKey(now);
    final from =
    UsageSync.dayKey(DateTime(now.year, now.month, now.day - (_days - 1)));
    final r = await ShadowDb.usageTopApps(from, to);
    // Hide system components (no readable app name) and this app itself.
    final visible = r
        .where((m) => m['label'] != m['package'] && m['package'] != _ownPackage)
        .toList();
    if (mounted) setState(() => _rows = visible);
  }

  String _fmt(int ms) {
    final m = (ms / 60000).round();
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${m % 60}m';
  }

  int _ms(Map<String, Object?> m) => ((m['total_ms'] as num?) ?? 0).toInt();

  @override
  Widget build(BuildContext context) {
    final total = _rows.fold<int>(0, (s, m) => s + _ms(m));
    final maxMs = _rows.isEmpty ? 1 : _ms(_rows.first);
    return Scaffold(
      appBar: AppBar(title: const Text('App usage')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Today')),
                ButtonSegment(value: 7, label: Text('7 days')),
              ],
              selected: {_days},
              onSelectionChanged: (s) {
                setState(() => _days = s.first);
                _refresh();
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            ),
          if (!_access && !_loading)
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                        'To show app usage, allow "Usage access" for this app. '
                            'The data stays on this phone.'),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: () => UsageReader.openSettings(),
                      child: const Text('Open usage access settings'),
                    ),
                  ],
                ),
              ),
            ),
          if (_access) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Total app time: ${_fmt(total)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: _rows.isEmpty && !_loading
                    ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No usage recorded for this period yet.'),
                    ),
                  ],
                )
                    : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: _rows.length > 15 ? 15 : _rows.length,
                  itemBuilder: (context, i) {
                    final m = _rows[i];
                    final ms = _ms(m);
                    final sessions =
                    ((m['sessions'] as num?) ?? 0).toInt();
                    return ListTile(
                      title: Text('${m['label']}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 4),
                          LinearProgressIndicator(value: ms / maxMs),
                          const SizedBox(height: 4),
                          Text('$sessions opens'),
                        ],
                      ),
                      trailing: Text(_fmt(ms)),
                    );
                  },
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Time an app was on screen, from Android usage stats. '
                    'System components and this app are hidden.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}