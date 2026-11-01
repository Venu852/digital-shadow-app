import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/sync/server_client.dart';
import 'package:test_app/ui/account_screen.dart';

// Kept apart from release_https_test.dart: widget tests replace HttpClient.
void main() {
  testWidgets('the account screen refuses http in release builds', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: AccountScreen(releaseMode: true)),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'http://127.0.0.1:5050');
    await tester.enterText(fields.at(1), 'alice');
    await tester.enterText(fields.at(2), 'password123');
    final pair = find.text('Sign in and pair this phone');
    await tester.ensureVisible(pair);
    await tester.tap(pair);
    await tester.pumpAndSettle();

    expect(find.text(releaseHttpsOnly), findsOneWidget);
  });
}
