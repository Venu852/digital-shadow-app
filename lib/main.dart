import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:test_app/ui/app_shell.dart';
import 'package:test_app/ui/consent_screen.dart';
import 'package:test_app/ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const DigitalShadowApp());
}

class DigitalShadowApp extends StatelessWidget {
  const DigitalShadowApp({super.key});

  @override
  Widget build(BuildContext context) =>
      MaterialApp(
        title: 'Digital Shadow',
        theme: buildShadowTheme(),
        home: const StartGate(),
      );
}

class StartGate extends StatefulWidget {
  const StartGate({super.key});

  @override
  State<StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<StartGate> {
  @override
  void initState() {
    super.initState();
    ConsentState.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool?>(
      valueListenable: ConsentState.accepted,
      builder: (context, accepted, _) {
        if (accepted == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return accepted ? const AppShell() : const ConsentScreen();
      },
    );
  }
}
