import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_app/sync/server_client.dart';

void main() {
  group('releaseAddressProblem', () {
    test('release builds accept only https addresses', () {
      for (final url in [
        'http://127.0.0.1:5050',
        'http://10.0.2.2:5050',
        'http://shadow.example.org',
        'ftp://shadow.example.org',
        'shadow.example.org',
        'https://',
        'not a url',
      ]) {
        expect(
          releaseAddressProblem(url, releaseMode: true),
          releaseHttpsOnly,
          reason: url,
        );
      }
      expect(
        releaseAddressProblem(
          'https://laptop.tail1234.ts.net',
          releaseMode: true,
        ),
        isNull,
      );
      expect(
        releaseAddressProblem(
          ' https://shadow.example.org ',
          releaseMode: true,
        ),
        isNull,
      );
    });

    test('debug builds leave the check to ServerClient', () {
      expect(
        releaseAddressProblem('http://127.0.0.1:5050', releaseMode: false),
        isNull,
      );
    });

    test('the message names release builds', () {
      expect(releaseHttpsOnly, 'Use an https:// address in release builds.');
    });
  });

  group('ServerClient in release mode', () {
    late HttpServer server;
    var hits = 0;

    setUp(() async {
      hits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        hits++;
        req.response.statusCode = 200;
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('refuses loopback http even when cleartext is allowed', () async {
      final r = await ServerClient(
        'http://127.0.0.1:${server.port}',
        token: 't',
        allowCleartext: true,
        releaseMode: true,
      ).me();
      expect(r.ok, isFalse);
      expect(r.failure, ApiFailure.network);
      expect(r.message, releaseHttpsOnly);

      final pair = await ServerClient(
        'http://127.0.0.1:${server.port}',
        allowCleartext: true,
        releaseMode: true,
      ).pair('alice', 'pw', 'My phone');
      expect(pair.message, releaseHttpsOnly);
      expect(hits, 0);
    });

    test('debug mode keeps the loopback cleartext option', () async {
      final r = await ServerClient(
        'http://127.0.0.1:${server.port}',
        token: 't',
        allowCleartext: true,
        releaseMode: false,
      ).deleteData();
      expect(r.ok, isTrue);
      expect(hits, 1);
    });

    test('an https address passes the check and is tried', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      final r = await ServerClient(
        'https://127.0.0.1:$port',
        token: 't',
        releaseMode: true,
        timeout: const Duration(seconds: 2),
      ).me();
      expect(r.failure, ApiFailure.network);
      expect(r.message, isNot(releaseHttpsOnly));
    });
  });
}
