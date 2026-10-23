/// Intervals are [onMs, offMs] in epoch milliseconds.
List<int> hourlyScreenMs(List<List<int>> intervals, int dayStartMs) {
  const hourMs = 3600000;
  final out = List<int>.filled(24, 0);
  for (final iv in intervals) {
    var a = iv[0] < dayStartMs ? dayStartMs : iv[0];
    final b = iv[1];
    while (a < b) {
      final idx = (a - dayStartMs) ~/ hourMs;
      if (idx < 0 || idx > 23) break;
      final bucketEnd = dayStartMs + (idx + 1) * hourMs;
      final seg = (b < bucketEnd ? b : bucketEnd) - a;
      if (seg <= 0) break;
      out[idx] += seg;
      a += seg;
    }
  }
  return out;
}

/// Share of the window (0..1) during which the screen was on.
double screenFraction(
    List<List<int>> intervals, int windowStartMs, int windowEndMs) {
  final len = windowEndMs - windowStartMs;
  if (len <= 0) return 0.0;
  var on = 0;
  for (final iv in intervals) {
    final a = iv[0] > windowStartMs ? iv[0] : windowStartMs;
    final b = iv[1] < windowEndMs ? iv[1] : windowEndMs;
    if (b > a) on += b - a;
  }
  final f = on / len;
  if (f < 0) return 0.0;
  if (f > 1) return 1.0;
  return f;
}