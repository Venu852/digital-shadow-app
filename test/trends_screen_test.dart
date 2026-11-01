import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/demo/demo_mode.dart';
import 'package:test_app/drift/drift_engine.dart';
import 'package:test_app/ui/how_it_works_screen.dart';
import 'package:test_app/ui/theme.dart';
import 'package:test_app/ui/trends_screen.dart';

DayDrift dd(String day, int? drift) => DayDrift(
  day: day,
  drift: drift,
  levels: {for (final k in signalKeys) k: drift},
  confidence: 80,
  dominant: 'switching',
  tz: '+00:00',
);

void main() {
  test('trend points are the scored days of the range, oldest first', () {
    final p = trendPoints(
      [
        dd('2026-10-31', 30),
        dd('2026-10-30', null),
        dd('2026-10-18', 12),
        dd('2026-10-17', 50),
      ],
      '2026-10-31',
      14,
    );
    expect(p.map((x) => x.day), ['2026-10-18', '2026-10-31']);
    expect(p.map((x) => x.index), [0, 13]);
    expect(DriftTrendPainter.xOf(0, 14, 330), DriftTrendPainter.leftAxis);
    expect(
      DriftTrendPainter.xOf(13, 14, 330),
      330 - DriftTrendPainter.rightPad,
    );
  });

  testWidgets('Trends shows the demo story', (tester) async {
    DemoMode.set(true);
    addTearDown(() => DemoMode.set(false));
    await tester.pumpWidget(
      MaterialApp(theme: buildShadowTheme(), home: const TrendsScreen()),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(find.text('52'), findsOneWidget);
    expect(find.text('Elevated drift'), findsOneWidget);
    expect(find.text('Drift over 14 days'), findsOneWidget);
    await tester.tap(find.text('30 days'));
    await tester.pump();
    expect(find.text('Drift over 30 days'), findsOneWidget);

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is DriftTrendPainter,
      ),
    );
    await tester.pump();
    expect(find.textContaining(': drift '), findsOneWidget);
  });

  testWidgets('How this works carries the worked example', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: buildShadowTheme(), home: const HowItWorksScreen()),
    );
    expect(find.text('What is measured'), findsOneWidget);
    for (final k in signalKeys) {
      expect(find.text(signalNames[k]!), findsOneWidget);
    }
    await tester.scrollUntilVisible(find.text('A worked example'), 200);
    expect(
      find.textContaining('their average is 32, which is Early drift'),
      findsOneWidget,
    );
  });
}
