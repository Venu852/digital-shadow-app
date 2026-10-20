import 'package:flutter/material.dart';
import 'package:test_app/service/usage_reader.dart';

class UsageTestScreen extends StatefulWidget {
  const UsageTestScreen({super.key});

  @override
  State<UsageTestScreen> createState() => _UsageTestScreenState();
}

class _UsageTestScreenState extends State<UsageTestScreen>
    with WidgetsBindingObserver {
  bool _access = false;
  bool _loading = false;
  String _error = '';
  List<AppUsage> _apps = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccess();
  }

  Future<void> _checkAccess() async {
    try {
      final ok = await UsageReader.hasAccess();
      if (mounted) {
        setState(() {
          _access = ok;
          _error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Access check failed: $e');
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final now = DateTime.now();
      final midnight = DateTime(now.year, now.month, now.day);
      final list = await UsageReader.query(midnight, now);
      list.sort((a, b) => b.totalMs.compareTo(a.totalMs));
      if (mounted) setState(() => _apps = list);
    } catch (e) {
      if (mounted) setState(() => _error = 'Query failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmt(int ms) {
    final m = (ms / 60000).round();
    if (m < 60) return '${m}m';
    return '${m ~/ 60}h ${m % 60}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Usage access test')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Usage access granted: ${_access ? 'YES' : 'NO'}'),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton(
                  onPressed: () => UsageReader.openSettings(),
                  child: const Text('Open usage access settings'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: (_access && !_loading) ? _load : null,
                  child: const Text("Load today's usage"),
                ),
              ],
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(),
            Expanded(
              child: ListView.builder(
                itemCount: _apps.length,
                itemBuilder: (context, i) {
                  final a = _apps[i];
                  return ListTile(
                    dense: true,
                    title: Text(a.label),
                    subtitle: Text(a.packageName),
                    trailing: Text('${_fmt(a.totalMs)} · ${a.sessions}x'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}