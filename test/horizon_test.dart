import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/drift/drift_engine.dart';

void main() {
  test('fewer than 4 values is not enough', () {
    expect(horizonFor(const []), 'Not enough days yet');
    expect(horizonFor(const [10, 30, 50]), 'Not enough days yet');
  });

  test('slope is the last value minus the one three entries earlier', () {
    // 99 is outside the window: 29 - 20 = 9.
    expect(horizonFor(const [99, 20, 0, 0, 29]),
        '2 to 3 weeks if the trend continues');
    // 0 is outside the window: 20 - 20 = 0.
    expect(horizonFor(const [0, 20, 90, 90, 20]),
        'No defined trend: stable or improving');
  });

  test('thresholds are strict: above 8, above 2', () {
    expect(horizonFor(const [20, 0, 0, 29]),
        '2 to 3 weeks if the trend continues');
    expect(horizonFor(const [20, 0, 0, 28]),
        '4 to 6 weeks if the trend continues');
    expect(horizonFor(const [20, 0, 0, 23]),
        '4 to 6 weeks if the trend continues');
    expect(horizonFor(const [20, 0, 0, 22]),
        'No defined trend: stable or improving');
    expect(horizonFor(const [40, 0, 0, 20]),
        'No defined trend: stable or improving');
  });
}
