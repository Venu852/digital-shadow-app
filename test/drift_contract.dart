/// The server's day-summary rules (digital-shadow-server app/devices.py
/// validate_summary), narrowed to what this phone may send: no forecast and
/// no unusual_hours. Returns an error message, or null when valid.
String? validateDayPayload(Object? data) {
  const required = {'drift', 'levels', 'confidence', 'baseline'};
  const allowed = {...required, 'tz'};
  const levelKeys = {
    'switching',
    'session',
    'checks',
    'screen',
    'night',
    'timing',
  };
  bool isInt(Object? v, int lo, int hi) => v is int && v >= lo && v <= hi;

  if (data is! Map) return 'Body must be a JSON object';
  final keys = data.keys.toSet();
  if (!keys.containsAll(required)) return 'Missing required field';
  if (keys.difference(allowed).isNotEmpty) return 'Unknown field';
  if (!isInt(data['drift'], 0, 100)) return 'drift must be an integer 0-100';
  final levels = data['levels'];
  if (levels is! Map ||
      levels.length != levelKeys.length ||
      !levels.keys.toSet().containsAll(levelKeys)) {
    return 'levels must have exactly: ${levelKeys.join(', ')}';
  }
  if (!levels.values.every((v) => isInt(v, 0, 100))) {
    return 'levels must be integers 0-100';
  }
  if (!isInt(data['confidence'], 0, 100)) {
    return 'confidence must be an integer 0-100';
  }
  if (data['baseline'] != 'calibrating' && data['baseline'] != 'established') {
    return "baseline must be 'calibrating' or 'established'";
  }
  if (data.containsKey('tz')) {
    final tz = data['tz'];
    if (tz is! String || !RegExp(r'^[+-](0\d|1[0-4]):[0-5]\d$').hasMatch(tz)) {
      return 'tz must look like +05:30';
    }
  }
  return null;
}
