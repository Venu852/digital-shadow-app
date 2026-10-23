import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/service/screen_state.dart';

void main() {
  const h = 3600000;

  test('hourlyScreenMs splits an interval across hours', () {
    final r = hourlyScreenMs([
      [30 * 60000, 90 * 60000]
    ], 0);
    expect(r[0], 30 * 60000);
    expect(r[1], 30 * 60000);
    expect(r.sublist(2).every((v) => v == 0), isTrue);
  });

  test('hourlyScreenMs clips to the start of the day', () {
    final r = hourlyScreenMs([
      [-h, h ~/ 2]
    ], 0);
    expect(r[0], h ~/ 2);
  });

  test('screenFraction full, half and none', () {
    final iv = [
      [0, 30000]
    ];
    expect(screenFraction(iv, 0, 30000), closeTo(1.0, 1e-9));
    expect(screenFraction(iv, 15000, 45000), closeTo(0.5, 1e-9));
    expect(screenFraction(iv, 40000, 70000), closeTo(0.0, 1e-9));
  });
}