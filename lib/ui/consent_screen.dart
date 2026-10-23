import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:test_app/data/db.dart';

class ConsentState {
  static const String key = 'consent_v1';
  static final ValueNotifier<bool?> accepted = ValueNotifier<bool?>(null);

  static Future<void> load() async {
    try {
      final v = await ShadowDb.getSetting(key);
      accepted.value = v != null && v.isNotEmpty;
    } catch (_) {
      accepted.value = false;
    }
  }

  static Future<void> accept() async {
    await ShadowDb.setSetting(key, DateTime.now().toUtc().toIso8601String());
    accepted.value = true;
  }

  static Future<void> withdraw() async {
    await ShadowDb.setSetting(key, '');
    accepted.value = false;
  }
}

class PrivacyDetails extends StatelessWidget {
  const PrivacyDetails({super.key});

  Widget _h(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(t, style: Theme.of(context).textTheme.titleMedium),
  );

  Widget _b(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text('•  $t'),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _h(context, 'What this app collects (on this phone only)'),
        _b('Motion: accelerometer and gyroscope readings, summarised into one '
            'record every 30 seconds while a session is running.'),
        _b('Phone state: battery level, charging, network type, and when the '
            'screen is on or off.'),
        _b('App usage (needs "Usage access"): which apps were on screen, for '
            'how long, how often they were opened and at what hour, plus '
            'phone unlocks and screen wake-ups.'),
        _h(context, 'What it does not collect'),
        _b('The content of your messages or screens.'),
        _b('Anything you type or touch.'),
        _b('Your location, contacts, photos, files, microphone or camera.'),
        _h(context, 'Where it stays'),
        _b('All data is stored only on this phone, in the app\'s private '
            'storage. This version does not upload anything.'),
        _b('You can delete everything or change how long data is kept in '
            'Settings, and you can switch off Usage access in Android '
            'settings at any time.'),
        _h(context, 'How it is used'),
        _b('The app compares each hour and each 30-second window with your '
            'own usual pattern and shows unusual ones, plus a simple '
            'prediction for the day.'),
        _b('It does not judge whether an app is good or bad for you.'),
      ],
    );
  }
}

class ConsentScreen extends StatelessWidget {
  const ConsentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Before you start')),
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: PrivacyDetails(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => SystemNavigator.pop(),
                    child: const Text('Decline and exit'),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () => ConsentState.accept(),
                    child: const Text('I agree and continue'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}