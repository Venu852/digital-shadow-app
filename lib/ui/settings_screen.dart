import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/usage_reader.dart';
import 'package:test_app/ui/account_screen.dart';
import 'package:test_app/ui/consent_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _usageAccess = false;
  int _retention = 30;
  int _windows = 0;
  int _usageDays = 0;
  bool _autoRestart = false;
  String _pairedAs = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final access = await UsageReader.hasAccess();
      final r =
          int.tryParse(await ShadowDb.getSetting('retention_days') ?? '') ?? 30;
      final w = await ShadowDb.countWindows();
      final d = (await ShadowDb.usageDaySummaries()).length;
      final ar = (await ShadowDb.getSetting('auto_restart')) == '1';
      final user = await ShadowDb.getSetting('paired_username') ?? '';
      if (mounted) {
        setState(() {
          _usageAccess = access;
          _retention = r;
          _windows = w;
          _usageDays = d;
          _autoRestart = ar;
          _pairedAs = user;
        });
      }
    } catch (_) {
      // Leave the previous values on screen.
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteAll() async {
    final ok = await _confirm('Delete all data?',
        'This removes every stored window, usage record and the learned '
            'baseline on this phone, and forgets its server pairing and any '
            'days waiting to upload. Your limits are kept.');
    if (!ok) return;
    await ShadowDb.deleteAll();
    await _load();
  }

  Future<void> _withdraw() async {
    final ok = await _confirm('Withdraw consent?',
        'This stops any running session, deletes all data and settings on '
            'this phone, and returns to the start screen.');
    if (!ok) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // No session was running.
    }
    await ShadowDb.deleteAll();
    await ShadowDb.deleteAllSettings();
    await ConsentState.withdraw();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(t, style: Theme.of(context).textTheme.titleMedium),
  );

  @override
  Widget build(BuildContext context) {
    final options = [7, 14, 30, 90];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _section('Permissions'),
          ListTile(
            title: const Text('Usage access'),
            subtitle: Text(_usageAccess ? 'Granted' : 'Not granted'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => UsageReader.openSettings(),
          ),
          ListTile(
            title: const Text('Keep running in the background'),
            subtitle: const Text(
                'Set this app to Unrestricted / Don\'t optimise battery'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => UsageReader.openBatterySettings(),
          ),
          ListTile(
            title: const Text('Notifications'),
            subtitle: const Text('Needed for the "session active" notice'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => UsageReader.openNotificationSettings(),
          ),
          _section('Account and sharing'),
          ListTile(
            title: const Text('Account and sharing'),
            subtitle: Text(_pairedAs.isEmpty
                ? 'Not paired. Nothing is uploaded.'
                : 'Paired as $_pairedAs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AccountScreen()),
              );
              await _load();
            },
          ),
          _section('Session'),
          SwitchListTile(
            title: const Text('Restart session after phone reboot'),
            subtitle: const Text(
                'Off by default. Takes effect the next time you start a '
                    'session. Some phones also need "Auto launch" allowed for '
                    'this app.'),
            value: _autoRestart,
            onChanged: (v) async {
              await ShadowDb.setSetting('auto_restart', v ? '1' : '0');
              if (mounted) setState(() => _autoRestart = v);
            },
          ),
          _section('Stored data'),
          ListTile(
            title: const Text('Motion windows stored'),
            trailing: Text('$_windows'),
          ),
          ListTile(
            title: const Text('Days of app usage stored'),
            trailing: Text('$_usageDays'),
          ),
          ListTile(
            title: const Text('Keep data for'),
            trailing: DropdownButton<int>(
              value: options.contains(_retention) ? _retention : 30,
              items: options
                  .map((d) =>
                  DropdownMenuItem(value: d, child: Text('$d days')))
                  .toList(),
              onChanged: (v) async {
                if (v == null) return;
                await ShadowDb.setSetting('retention_days', '$v');
                await ShadowDb.applyRetention(v);
                await _load();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _deleteAll,
                  child: const Text('Delete all data'),
                ),
                OutlinedButton(
                  onPressed: _withdraw,
                  child: const Text('Withdraw consent and delete everything'),
                ),
              ],
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: PrivacyDetails(),
          ),
        ],
      ),
    );
  }
}