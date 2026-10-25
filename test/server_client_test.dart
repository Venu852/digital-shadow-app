import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/sync/server_client.dart';

class Seen {
  final String method;
  final String path;
  final String? auth;
  final String? contentType;
  final String body;

  Seen(this.method, this.path, this.auth, this.contentType, this.body);
}

void main() {
  late HttpServer server;
  late String base;
  final seen = <Seen>[];
  // What the fake server answers next: status and JSON body (null = empty).
  var reply = (200, <String, Object?>{} as Object?);

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seen.add(Seen(
        req.method,
        req.uri.path,
        req.headers.value(HttpHeaders.authorizationHeader),
        req.headers.contentType?.mimeType,
        body,
      ));
      req.response.statusCode = reply.$1;
      if (reply.$2 != null) {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(reply.$2));
      }
      await req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  ServerClient client({String? token = 'tok-123'}) =>
      ServerClient(base, token: token, allowCleartext: true);

  test('pair ok sends credentials without a bearer header', () async {
    reply = (201, {'device_id': 'abc', 'device_token': 'secret-token'});
    final r = await client(token: null).pair('alice', 'pw', 'My phone');
    expect(r.ok, isTrue);
    expect(r.status, 201);
    expect(r.value!.deviceId, 'abc');
    expect(r.value!.deviceToken, 'secret-token');
    expect(r.value.toString(), isNot(contains('secret-token')));
    expect(seen.single.method, 'POST');
    expect(seen.single.path, '/api/devices/pair');
    expect(seen.single.auth, isNull);
    expect(seen.single.contentType, 'application/json');
    expect(jsonDecode(seen.single.body),
        {'username': 'alice', 'password': 'pw', 'device_name': 'My phone'});
  });

  test('pair error carries the server message', () async {
    reply = (401, {'error': 'Incorrect username or password.'});
    final r = await client(token: null).pair('alice', 'bad', 'My phone');
    expect(r.ok, isFalse);
    expect(r.status, 401);
    expect(r.failure, ApiFailure.unauthorized);
    expect(r.message, 'Incorrect username or password.');
  });

  test('token routes send the bearer header', () async {
    reply = (200,
    {'device_id': 'abc', 'username': 'alice', 'sharing_level': 'my_trend'});
    final me = await client().me();
    expect(me.value!.username, 'alice');
    expect(me.value!.sharingLevel, 'my_trend');
    expect(seen.last.method, 'GET');
    expect(seen.last.path, '/api/device/me');
    expect(seen.last.auth, 'Bearer tok-123');

    reply = (200, {'level': 'team_totals', 'changed_at': 'x'});
    final s = await client().putSharing('team_totals');
    expect(s.value, 'team_totals');
    expect(seen.last.method, 'PUT');
    expect(seen.last.path, '/api/device/sharing');
    expect(seen.last.auth, 'Bearer tok-123');
    expect(jsonDecode(seen.last.body), {'level': 'team_totals'});

    reply = (200, {'stored': true, 'updated': true});
    final d = await client().putDay('2026-10-24', {'drift': 1});
    expect(d.ok, isTrue);
    expect(d.value, isTrue);
    expect(seen.last.path, '/api/device/days/2026-10-24');
    expect(seen.last.auth, 'Bearer tok-123');
    expect(seen.last.contentType, 'application/json');
  });

  test('DELETE sends a JSON content type and {}', () async {
    reply = (204, null);
    final r = await client().deleteData();
    expect(r.ok, isTrue);
    expect(r.status, 204);
    expect(seen.single.method, 'DELETE');
    expect(seen.single.path, '/api/device/data');
    expect(seen.single.auth, 'Bearer tok-123');
    expect(seen.single.contentType, 'application/json');
    expect(seen.single.body, '{}');
  });

  test('HTTP errors map to failures with the server message', () async {
    final cases = {
      401: ApiFailure.unauthorized,
      403: ApiFailure.sharingOff,
      400: ApiFailure.invalid,
      413: ApiFailure.tooLarge,
      429: ApiFailure.rateLimited,
      500: ApiFailure.other,
    };
    for (final e in cases.entries) {
      reply = (e.key, {'error': 'message ${e.key}'});
      final r = await client().putDay('2026-10-24', {'drift': 1});
      expect(r.ok, isFalse);
      expect(r.status, e.key);
      expect(r.failure, e.value);
      expect(r.message, 'message ${e.key}');
    }
  });

  test('error without a JSON body still gives a message', () async {
    reply = (502, null);
    final r = await client().me();
    expect(r.failure, ApiFailure.other);
    expect(r.message, 'HTTP 502');
  });

  test('network failure is a result, not an exception', () async {
    final port = server.port;
    await server.close(force: true);
    final r = await ServerClient('http://127.0.0.1:$port',
        token: 't', allowCleartext: true)
        .putDay('2026-10-24', {'drift': 1});
    expect(r.ok, isFalse);
    expect(r.failure, ApiFailure.network);
    expect(r.status, isNull);
    expect(r.message, isNotEmpty);
  });

  test('a server that never answers times out as a network error', () async {
    final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final held = <HttpRequest>[];
    silent.listen(held.add);
    final r = await ServerClient('http://127.0.0.1:${silent.port}',
        token: 't',
        allowCleartext: true,
        timeout: const Duration(milliseconds: 300))
        .me();
    expect(r.failure, ApiFailure.network);
    expect(r.message, 'The server did not answer in time');
    await silent.close(force: true);
  });

  test('plain http is refused unless allowed and local', () async {
    final remote = await ServerClient('http://example.org', token: 't',
        allowCleartext: true)
        .me();
    expect(remote.failure, ApiFailure.network);
    expect(remote.message, 'Use an https:// address');

    final notAllowed = await ServerClient(base, token: 't').me();
    expect(notAllowed.message, 'Use an https:// address');

    final bad = await ServerClient('not a url', token: 't').me();
    expect(bad.message, 'Invalid server address');
    expect(seen, isEmpty);
  });
}
