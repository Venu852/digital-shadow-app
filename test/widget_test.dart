import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/main.dart';

void main() {
  testWidgets('Home screen shows start button', (tester) async {
    await tester.pumpWidget(const DigitalShadowApp());
    expect(find.text('Start session'), findsOneWidget);
  });
}