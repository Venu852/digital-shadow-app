import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:test_app/data/db.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/service/usage_reader.dart';
import 'package:test_app/sync/sync_service.dart';
import 'package:test_app/ui/account_screen.dart';
import 'package:test_app/ui/consent_screen.dart';
import 'package:test_app/ui/how_it_works_screen.dart';
import 'package:test_app/ui/sharing.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/today_model.dart';

const List<String> ethicalGuarantees = [
  'No identity inference',
  'No mental-health claims or diagnostic language',
  'No individual punishment mechanisms',
  'No biometric, voice, facial or content data',
  'Sharing can be paused at any time with no penalty',
];

class _SentRow {
  final String day;
  final String sentAt;
  final String payloadJson;

  const _SentRow(this.day, this.sentAt, this.payloadJson);
}

/// Sharing, account, data controls and the privacy details.
class PrivacyTab extends StatefulWidget {
  /// Changes when the shell shows another tab; the tab reloads on visit.
  final ValueNotifier<int>? tab;
  final int index;

  const PrivacyTab({super.key, this.tab, this.index = 4});

  @override
  State<PrivacyTab> createState() => _PrivacyTabState();
}

class _PrivacyTabState extends State<PrivacyTab> with WidgetsBindingObserver {
  final SharingControl _control = SharingControl.instance;

  bool _usageAccess = false;
  int _retention = 30;
  int _windows = 0;
  int _usageDays = 0;
  bool _autoRestart = false;
  bool _paired = false;
  bool _busy = false;
  SharingState _sharing = const SharingState('nothing');
  String? _context;
  List<_SentRow> _sent = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tab?.addListener(_onTab);
    _load();
  }

  @override
  void dispose() {
    widget.tab?.removeListener(_onTab);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  void _onTab() {
    if (widget.tab?.value == widget.index) _load();
  }

  Future<void> _load() async {
    try {
      final access = await UsageReader.hasAccess();
      final r =
          int.tryParse(await ShadowDb.getSetting('retention_days') ?? '') ?? 30;
      final w = await ShadowDb.countWindows();
      final d = (await ShadowDb.usageDaySummaries()).length;
      final ar = (await ShadowDb.getSetting('auto_restart')) == '1';
      final paired =
          await SyncService.instance.isPaired() &&
          await ShadowDb.getSetting('sync_status') != SyncStatus.signedOut;
      final sharing = await _control.load();
      final ctx = await ShadowDb.getSetting(personalContextKey);
      final sent = [
        for (final m in await ShadowDb.outboxSent(30))
          _SentRow('${m['day']}', '${m['sent_at']}', '${m['payload_json']}'),
      ];
      if (mounted) {
        setState(() {
          _usageAccess = access;
          _retention = r;
          _windows = w;
          _usageDays = d;
          _autoRestart = ar;
          _paired = paired;
          _sharing = sharing;
          _context = personalContexts.contains(ctx) ? ctx : null;
          _sent = sent;
        });
      }
    } catch (_) {
      // Leave the previous values on screen.
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _sharingAction(
    Future<String?> Function() action,
    String done,
  ) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final error = await action();
      _snack(error ?? done);
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _setLevel(String level) async {
    if (level == _sharing.level && !_sharing.paused) return;
    await _sharingAction(
      () => _control.setLevel(level),
      'Sharing set to ${sharingLabels[level]}.',
    );
  }

  Future<void> _setContext(String? value) async {
    await ShadowDb.setSetting(personalContextKey, value ?? '');
    if (mounted) setState(() => _context = value);
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
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteAll() async {
    final ok = await _confirm(
      'Delete all data?',
      'This removes every stored window, usage record and the learned '
          'baseline on this phone, and forgets its server pairing and any '
          'days waiting to upload. Your limits are kept.',
    );
    if (!ok) return;
    await ShadowDb.deleteAll();
    DemoMode.clearMemory();
    await ShadowDb.deleteSettings(const [
      SharingControl.pausedSinceKey,
      SharingControl.beforePauseKey,
    ]);
    await _load();
  }

  Future<void> _withdraw() async {
    final ok = await _confirm(
      'Withdraw consent?',
      'This stops any running session, deletes all data and settings on '
          'this phone, and returns to the start screen.',
    );
    if (!ok) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // No session was running.
    }
    await ShadowDb.deleteAll();
    await ShadowDb.deleteAllSettings();
    DemoMode.set(false);
    await ConsentState.withdraw();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _showPayload(_SentRow r) {
    String pretty;
    try {
      pretty = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(r.payloadJson));
    } catch (_) {
      pretty = r.payloadJson;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Sent for ${formatDay(r.day)}'),
        content: SingleChildScrollView(
          child: SelectableText(
            pretty,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(t, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _secondary(String t) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Text(t, style: const TextStyle(color: ShadowColors.textSecondary)),
  );

  Widget _levelOption(String level) {
    final selected = !_sharing.paused && _sharing.level == level;
    final enabled = _paired && !_busy;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: selected ? ShadowColors.selected : ShadowColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? ShadowColors.selectedBorder : ShadowColors.border,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? () => _setLevel(level) : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: minTouchTarget),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? ShadowColors.primary
                        : ShadowColors.textSecondary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sharingLabels[level]!,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: enabled
                                ? ShadowColors.text
                                : ShadowColors.textSecondary,
                          ),
                        ),
                        Text(
                          sharingHelp[level]!,
                          style: const TextStyle(
                            color: ShadowColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _sharingSection() => [
    _section('Sharing'),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SharingChip(_sharing),
      ),
    ),
    if (!_paired)
      _secondary(
        'Pair this phone below to choose what you share. '
        'Until then nothing is uploaded.',
      ),
    for (final level in sharingLabels.keys) _levelOption(level),
    if (_sharing.paused)
      _secondary(
        'Paused ${_sharing.pausedDays(DateTime.now())} day(s) '
        'ago. Sharing stays off until you resume it.',
      ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _sharing.paused
            ? FilledButton(
                onPressed: _busy || !_paired
                    ? null
                    : () => _sharingAction(_control.resume, 'Sharing resumed.'),
                child: const Text('Resume sharing'),
              )
            : OutlinedButton(
                onPressed: _busy || !_paired || _sharing.level == 'nothing'
                    ? null
                    : () => _sharingAction(_control.pause, 'Sharing paused.'),
                child: const Text('Pause sharing'),
              ),
      ),
    ),
  ];

  List<Widget> _contextSection() => [
    _section('Personal context'),
    _secondary(
      'Mark a stretch of unusual days. While one is active, your '
      'drift is shown 15 lower. It stays on this phone and never '
      'changes what is uploaded.',
    ),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final c in personalContexts)
            ChoiceChip(
              label: Text(c),
              selected: _context == c,
              showCheckmark: false,
              onSelected: (on) => _setContext(on ? c : null),
            ),
        ],
      ),
    ),
  ];

  List<Widget> _sentSection() => [
    _section('What I sent'),
    if (_sent.isEmpty)
      _secondary('Nothing has been sent from this phone.')
    else ...[
      _secondary(
        'The last ${_sent.length} uploads, newest first. Tap one '
        'to see exactly what was sent.',
      ),
      for (final r in _sent)
        ListTile(
          title: Text(formatDay(r.day)),
          subtitle: Text(
            'Sent ${DateTime.tryParse(r.sentAt)?.toLocal().toString().substring(0, 16) ?? r.sentAt}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showPayload(r),
        ),
    ],
  ];

  List<Widget> _demoSection() => [
    _section('Demo'),
    ValueListenableBuilder<bool>(
      valueListenable: DemoMode.enabled,
      builder: (context, on, _) => SwitchListTile(
        title: const Text(DemoMode.toggleLabel),
        subtitle: const Text(
          'Shows a made-up 21-day story on Today, Trends and Why. Nothing is '
          'saved or uploaded while it is on, and turning it off brings back '
          'your own data.',
        ),
        value: on,
        onChanged: DemoMode.set,
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final options = [7, 14, 30, 90];
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ..._sharingSection(),
          ..._contextSection(),
          ..._sentSection(),
          ..._demoSection(),
          _section('Account and pairing'),
          AccountScreen(embedded: true, onChanged: _load),
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
              'Set this app to Unrestricted / Don\'t optimise battery',
            ),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => UsageReader.openBatterySettings(),
          ),
          ListTile(
            title: const Text('Notifications'),
            subtitle: const Text('Needed for the "session active" notice'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => UsageReader.openNotificationSettings(),
          ),
          _section('Session'),
          SwitchListTile(
            title: const Text('Restart session after phone reboot'),
            subtitle: const Text(
              'Off by default. Takes effect the next time you start a '
              'session. Some phones also need "Auto launch" allowed for '
              'this app.',
            ),
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
                  .map(
                    (d) => DropdownMenuItem(value: d, child: Text('$d days')),
                  )
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
              runSpacing: 8,
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
          _section('Our guarantees'),
          for (final g in ethicalGuarantees)
            ListTile(
              leading: const Icon(Icons.check, color: ShadowColors.primary),
              title: Text(g),
            ),
          ListTile(
            title: const Text('How this works'),
            subtitle: const Text('The signals, your baseline and what is shared'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HowItWorksScreen()),
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
