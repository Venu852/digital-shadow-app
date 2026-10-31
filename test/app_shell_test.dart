import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/ui/app_shell.dart';
import 'package:test_app/ui/theme.dart';

void main() {
  testWidgets('the shell shows the five destinations', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildShadowTheme(),
      home: AppShell(pageFor: (i, _) => Text('page $i')),
    ));

    expect(find.byType(NavigationDestination), findsNWidgets(5));
    for (final label in ['Today', 'Trends', 'Why', 'Usage', 'Privacy']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('page 0'), findsOneWidget);

    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    expect(find.text('page 4'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsNothing);
  });
}
