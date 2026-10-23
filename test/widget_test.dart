import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/ui/consent_screen.dart';

void main() {
  testWidgets('Consent screen lists what is collected and what is not',
          (tester) async {
        await tester.pumpWidget(const MaterialApp(home: ConsentScreen()));
        expect(find.text('I agree and continue'), findsOneWidget);
        expect(find.text('Decline and exit'), findsOneWidget);
        expect(find.text('What it does not collect'), findsOneWidget);
      });
}