import 'package:flutter/foundation.dart';

/// Prints [message] in debug builds only. Never pass tokens, passwords or
/// payloads that identify the person.
void dlog(String message) {
  if (kDebugMode) debugPrint(message);
}
