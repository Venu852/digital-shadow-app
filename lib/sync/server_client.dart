import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;

/// Release builds talk to the server only over HTTPS.
const String releaseHttpsOnly = 'Use an https:// address in release builds.';

/// Why [url] cannot be a server address in a release build, or null when it
/// can (or when [releaseMode] is false). Debug builds keep the loopback
/// cleartext option, which [ServerClient] checks itself.
String? releaseAddressProblem(String url, {bool releaseMode = kReleaseMode}) {
  if (!releaseMode) return null;
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return releaseHttpsOnly;
  }
  return null;
}

/// Why a request did not succeed. [none] means it did.
enum ApiFailure {
  none,
  network,
  unauthorized,
  sharingOff,
  invalid,
  tooLarge,
  rateLimited,
  other,
}

ApiFailure failureForStatus(int status) {
  if (status >= 200 && status < 300) return ApiFailure.none;
  switch (status) {
    case 400:
      return ApiFailure.invalid;
    case 401:
      return ApiFailure.unauthorized;
    case 403:
      return ApiFailure.sharingOff;
    case 413:
      return ApiFailure.tooLarge;
    case 429:
      return ApiFailure.rateLimited;
    default:
      return ApiFailure.other;
  }
}

/// Outcome of one request: a value, an HTTP error with the server's message,
/// or a network error. Never holds the token or password.
class ApiResult<T> {
  final ApiFailure failure;
  final T? value;
  final int? status;
  final String? message;

  const ApiResult._(this.failure, this.value, this.status, this.message);

  const ApiResult.ok(T this.value, int this.status)
      : failure = ApiFailure.none,
        message = null;

  ApiResult.http(int status, String message)
      : this._(failureForStatus(status), null, status, message);

  const ApiResult.network(String this.message)
      : failure = ApiFailure.network,
        value = null,
        status = null;

  bool get ok => failure == ApiFailure.none;
}

class PairResult {
  final String deviceId;
  final String deviceToken;

  const PairResult(this.deviceId, this.deviceToken);

  @override
  String toString() => 'PairResult($deviceId)';
}

class DeviceMe {
  final String deviceId;
  final String username;
  final String sharingLevel;

  const DeviceMe(this.deviceId, this.username, this.sharingLevel);
}

/// Talks to the Digital Shadow server with dart:io only. Never throws for
/// HTTP or network errors and never logs anything.
class ServerClient {
  static const Set<String> cleartextHosts = {
    '127.0.0.1',
    'localhost',
    '10.0.2.2',
  };

  final String baseUrl;
  final String? token;
  final Duration timeout;

  /// Plain http is allowed only when this is true and the host is one of
  /// [cleartextHosts] (debug builds talking to a local server).
  final bool allowCleartext;

  /// True in release builds: only https:// addresses, whatever
  /// [allowCleartext] says. Injectable so tests can check it.
  final bool releaseMode;

  ServerClient(
      this.baseUrl, {
        this.token,
        this.timeout = const Duration(seconds: 10),
        this.allowCleartext = false,
        this.releaseMode = kReleaseMode,
      });

  /// Returns null and a reason when the address cannot be used.
  (Uri?, String?) _uri(String path) {
    final Uri base;
    try {
      base = Uri.parse(baseUrl.trim());
    } on FormatException {
      return (null, 'Invalid server address');
    }
    if (base.host.isEmpty || (base.scheme != 'http' && base.scheme != 'https')) {
      return (null, 'Invalid server address');
    }
    if (releaseMode && base.scheme != 'https') {
      return (null, releaseHttpsOnly);
    }
    if (base.scheme == 'http' &&
        !(allowCleartext && cleartextHosts.contains(base.host))) {
      return (null, 'Use an https:// address');
    }
    return (base.replace(path: path, query: null, fragment: null), null);
  }

  Future<ApiResult<Object?>> _send(String method, String path,
      {Object? body, bool auth = true}) async {
    final (uri, problem) = _uri(path);
    if (uri == null) return ApiResult.network(problem!);
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (auth) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${token ?? ''}');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      Object? json;
      if (text.isNotEmpty) {
        try {
          json = jsonDecode(text);
        } on FormatException {
          json = null;
        }
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return ApiResult.ok(json, res.statusCode);
      }
      final error = json is Map ? json['error'] : null;
      return ApiResult.http(
          res.statusCode, error is String ? error : 'HTTP ${res.statusCode}');
    } on TimeoutException {
      return const ApiResult.network('The server did not answer in time');
    } on SocketException {
      return const ApiResult.network('Could not reach the server');
    } on TlsException {
      return const ApiResult.network('Secure connection failed');
    } on Exception {
      return const ApiResult.network('Could not reach the server');
    } finally {
      client.close(force: true);
    }
  }

  ApiResult<T> _bad<T>(ApiResult<Object?> r) =>
      ApiResult.http(r.status ?? 0, 'Unexpected response from the server');

  ApiResult<T> _carry<T>(ApiResult<Object?> r) => r.failure == ApiFailure.network
      ? ApiResult.network(r.message!)
      : ApiResult.http(r.status!, r.message!);

  /// The password is sent once here and never kept.
  Future<ApiResult<PairResult>> pair(
      String username, String password, String deviceName) async {
    final r = await _send('POST', '/api/devices/pair',
        body: {
          'username': username,
          'password': password,
          'device_name': deviceName,
        },
        auth: false);
    if (!r.ok) return _carry(r);
    final v = r.value;
    if (v is Map && v['device_id'] is String && v['device_token'] is String) {
      return ApiResult.ok(
          PairResult(v['device_id'] as String, v['device_token'] as String),
          r.status!);
    }
    return _bad(r);
  }

  Future<ApiResult<DeviceMe>> me() async {
    final r = await _send('GET', '/api/device/me');
    if (!r.ok) return _carry(r);
    final v = r.value;
    if (v is Map &&
        v['device_id'] is String &&
        v['username'] is String &&
        v['sharing_level'] is String) {
      return ApiResult.ok(
          DeviceMe(v['device_id'] as String, v['username'] as String,
              v['sharing_level'] as String),
          r.status!);
    }
    return _bad(r);
  }

  /// Returns the level the server now holds.
  Future<ApiResult<String>> putSharing(String level) async {
    final r =
    await _send('PUT', '/api/device/sharing', body: {'level': level});
    if (!r.ok) return _carry(r);
    final v = r.value;
    if (v is Map && v['level'] is String) {
      return ApiResult.ok(v['level'] as String, r.status!);
    }
    return _bad(r);
  }

  /// Returns true when the server replaced an earlier upload for [day].
  Future<ApiResult<bool>> putDay(
      String day, Map<String, Object?> payload) async {
    final r = await _send('PUT', '/api/device/days/$day', body: payload);
    if (!r.ok) return _carry(r);
    final v = r.value;
    if (v is Map && v['stored'] == true) {
      return ApiResult.ok(v['updated'] == true, r.status!);
    }
    return _bad(r);
  }

  /// The server needs a JSON body even for DELETE, so this sends {}.
  Future<ApiResult<bool>> deleteData() async {
    final r = await _send('DELETE', '/api/device/data', body: const {});
    if (!r.ok) return _carry(r);
    return ApiResult.ok(true, r.status!);
  }
}
