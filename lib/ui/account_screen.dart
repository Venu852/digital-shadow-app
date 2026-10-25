import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/service/usage_sync.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/sync/sync_service.dart';

/// "+05:30" style offset, as the server expects in `tz`.
String formatTzOffset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final m = offset.inMinutes.abs();
  return '$sign${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  static const Map<String, String> _levels = {
    'nothing': 'Nothing',
    'team_totals': 'Group totals only',
    'my_trend': 'My drift trend',
  };
  static const Map<String, String> _levelHelp = {
    'nothing': 'Nothing leaves this phone.',
    'team_totals': 'Your days count towards your group\'s totals only. '
        'Nobody sees your own trend.',
    'my_trend': 'Your group coordinator can also see your own drift trend.',
  };

  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _deviceName = TextEditingController(text: 'My phone');

  final SyncService _sync = SyncService.instance;
  bool _loaded = false;
  bool _busy = false;
  bool _hasPairing = false;
  String _pairedAs = '';
  String _level = 'nothing';
  String? _status;
  String? _lastSync;
  int _waiting = 0;
  int _failedCount = 0;
  String? _lastError;
  String? _pairError;

  bool get _paired => _hasPairing && _status != SyncStatus.signedOut;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _refreshFromServer());
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final url = await ShadowDb.getSetting('server_url') ?? '';
      final hasPairing = await _sync.isPaired();
      final user = await ShadowDb.getSetting('paired_username') ?? '';
      final level = await ShadowDb.getSetting('sharing_level') ?? 'nothing';
      final status = await ShadowDb.getSetting('sync_status');
      final last = await ShadowDb.getSetting('last_sync_at');
      final waiting = await _sync.outbox.pendingCount();
      final failed = await _sync.outbox.failed();
      if (!mounted) return;
      setState(() {
        if (_url.text.isEmpty) _url.text = url;
        _hasPairing = hasPairing;
        _pairedAs = user;
        _level = _levels.containsKey(level) ? level : 'nothing';
        _status = (status ?? '').isEmpty ? null : status;
        _lastSync = (last ?? '').isEmpty ? null : last;
        _waiting = waiting;
        _failedCount = failed.length;
        _lastError = failed.isEmpty
            ? null
            : '${failed.first.day}: ${failed.first.lastError}';
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  /// Picks up a sharing level changed on the dashboard. Silent on errors.
  Future<void> _refreshFromServer() async {
    if (!_paired) return;
    final client = await _sync.client();
    if (client == null) return;
    final r = await client.me();
    if (r.ok) {
      await ShadowDb.setSetting('sharing_level', r.value!.sharingLevel);
    } else if (r.failure == ApiFailure.unauthorized) {
      await ShadowDb.setSetting('sync_status', SyncStatus.signedOut);
    }
    await _load();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm(String title, String body, String action) async {
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
              child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _pair() => _guard(() async {
    var url = _url.text.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    final user = _username.text.trim().toLowerCase();
    final password = _password.text;
    final name = _deviceName.text.trim();
    // The password is used for this one request and never stored.
    _password.clear();
    String? error;
    if (url.isEmpty) {
      error = 'Enter the server address.';
    } else if (user.isEmpty || password.isEmpty) {
      error = 'Enter your username and password.';
    } else if (name.isEmpty || name.length > 40) {
      error = 'The device name must be 1 to 40 characters.';
    }
    if (error != null) {
      setState(() => _pairError = error);
      return;
    }
    final r = await ServerClient(url, allowCleartext: kDebugMode)
        .pair(user, password, name);
    if (!r.ok) {
      setState(() => _pairError = r.message);
      return;
    }
    final paired = r.value!;
    await _sync.savePairing(
      serverUrl: url,
      deviceId: paired.deviceId,
      deviceToken: paired.deviceToken,
      username: user,
    );
    final me = await (await _sync.client())!.me();
    await ShadowDb.setSetting(
        'sharing_level', me.ok ? me.value!.sharingLevel : 'nothing');
    if (mounted) setState(() => _pairError = null);
    _snack('This phone is paired.');
  });

  Future<void> _setLevel(String? level) async {
    if (level == null || level == _level) return;
    await _guard(() async {
      // Choosing Nothing stops uploads on this phone before asking the server.
      if (level == 'nothing') {
        await ShadowDb.setSetting('sharing_level', 'nothing');
      }
      final client = await _sync.client();
      if (client == null) return;
      final r = await client.putSharing(level);
      if (r.ok) {
        await ShadowDb.setSetting('sharing_level', r.value!);
        _snack('Sharing set to ${_levels[r.value!] ?? r.value!}.');
        return;
      }
      if (r.failure == ApiFailure.unauthorized) {
        await ShadowDb.setSetting('sync_status', SyncStatus.signedOut);
      }
      _snack(level == 'nothing'
          ? 'Uploads are stopped on this phone, but the server could not be '
          'told: ${r.message}'
          : 'Sharing was not changed: ${r.message}');
    });
  }

  String _resultText(SyncResult r) {
    switch (r.state) {
      case SyncState.notPaired:
        return 'This phone is not paired.';
      case SyncState.signedOut:
        return SyncStatus.describe(SyncStatus.signedOut);
      case SyncState.sharingOff:
        return 'Sharing is set to Nothing, so nothing was uploaded.';
      case SyncState.throttled:
      case SyncState.busy:
        return 'A sync is already running.';
      case SyncState.done:
        return r.failed > 0
            ? 'Uploaded ${r.sent} day(s); ${r.failed} not accepted.'
            : 'Uploaded ${r.sent} day(s).';
      case SyncState.stopped:
        return '${SyncStatus.describe(r.status)} (${r.message})';
    }
  }

  Future<void> _syncNow() => _guard(() async {
    _snack(_resultText(await _sync.run(force: true)));
  });

  Future<void> _sendTestSummary() => _guard(() async {
    final now = DateTime.now();
    await _sync.outbox.enqueue(UsageSync.dayKey(now), {
      'drift': 34,
      'levels': {
        'switching': 55,
        'session': 40,
        'checks': 35,
        'screen': 30,
        'night': 20,
        'timing': 25,
      },
      'confidence': 76,
      'baseline': 'established',
      'tz': formatTzOffset(now.timeZoneOffset),
    });
    _snack(_resultText(await _sync.run(force: true)));
  });

  Future<void> _deleteServerData() async {
    final ok = await _confirm(
        'Delete your data on the server?',
        'This removes every daily summary this phone has uploaded. '
            'The phone stays paired.',
        'Delete');
    if (!ok) return;
    await _guard(() async {
      final client = await _sync.client();
      if (client == null) return;
      final r = await client.deleteData();
      if (r.failure == ApiFailure.unauthorized) {
        await ShadowDb.setSetting('sync_status', SyncStatus.signedOut);
      }
      _snack(r.ok
          ? 'Your data on the server was deleted.'
          : 'Nothing was deleted: ${r.message}');
    });
  }

  Future<void> _unpair() async {
    final ok = await _confirm(
        'Unpair this phone?',
        'This phone forgets its sign-in and stops uploading. Days that are '
            'still waiting stay on this phone.',
        'Unpair');
    if (!ok) return;
    await _guard(_sync.forgetPairing);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Phone unpaired'),
        content: const Text(
            'Also revoke this phone on the dashboard, under your devices, so '
                'its old sign-in can never be used again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(t, style: Theme.of(context).textTheme.titleMedium),
  );

  List<Widget> _pairForm() => [
    if (_hasPairing && _status == SyncStatus.signedOut)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(SyncStatus.describe(SyncStatus.signedOut)),
      ),
    _section('Sign in'),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Server address',
              hintText: kDebugMode
                  ? 'http://127.0.0.1:5050'
                  : 'https://shadow.example.org',
            ),
          ),
          TextField(
            controller: _username,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          TextField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          TextField(
            controller: _deviceName,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Device name'),
          ),
          if (_pairError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_pairError!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _busy ? null : _pair,
              child: const Text('Sign in and pair this phone'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
              'Your password is used once to pair this phone and is not '
                  'stored.'),
        ],
      ),
    ),
  ];

  List<Widget> _pairedView() => [
    ListTile(
      title: Text('Paired as $_pairedAs'),
      subtitle: Text(_url.text),
    ),
    _section('What you share'),
    RadioGroup<String>(
      groupValue: _level,
      onChanged: _setLevel,
      child: Column(
        children: [
          for (final e in _levels.entries)
            RadioListTile<String>(
              value: e.key,
              enabled: !_busy,
              title: Text(e.value),
              subtitle: Text(_levelHelp[e.key]!),
            ),
        ],
      ),
    ),
    _section('Uploads'),
    ListTile(
      title: const Text('Last upload'),
      subtitle: Text(_lastSync == null
          ? 'Never'
          : DateTime.parse(_lastSync!).toLocal().toString().substring(0, 16)),
    ),
    ListTile(
      title: const Text('Days waiting'),
      trailing: Text('$_waiting'),
    ),
    ListTile(
      title: const Text('Status'),
      subtitle: Text(SyncStatus.describe(_status)),
    ),
    if (_lastError != null)
      ListTile(
        title: Text('Not accepted ($_failedCount)'),
        subtitle: Text(_lastError!),
      ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: _busy ? null : _syncNow,
            child: const Text('Sync now'),
          ),
          if (kDebugMode)
            OutlinedButton(
              onPressed: _busy ? null : _sendTestSummary,
              child: const Text('Send test summary'),
            ),
          OutlinedButton(
            onPressed: _busy ? null : _deleteServerData,
            child: const Text('Delete my data on the server'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _unpair,
            child: const Text('Unpair this phone'),
          ),
        ],
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account and sharing')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: _paired ? _pairedView() : _pairForm(),
      ),
    );
  }
}
