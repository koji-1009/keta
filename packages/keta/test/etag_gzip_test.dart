@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide gzip;
import 'dart:io' as io show gzip;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

Env newEnv() => Env(StdoutLog(flushInterval: Duration.zero));

Future<Env> boot() async => Env(StdoutLog(flushInterval: Duration.zero));

/// Runs [mw] against a fixed [response], returning the transformed response.
Future<Response> run(
  Middleware<Env> mw,
  Context<Env> c,
  Response response,
) async => mw(c, (_) => response);

void main() {
  group('etag — 304 semantics', () {
    test('tags a 200 with a buffered body, then 304s a match', () async {
      final tagged = await run(
        etag(),
        testContext(newEnv()),
        Response.text('hi'),
      );
      expect(tagged.status, 200);
      final tag = tagged.headers['etag']!.single;
      expect(tag, startsWith('"'));

      final conditional = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': tag}),
        Response.text('hi'),
      );
      expect(conditional.status, 304);
      expect(conditional.body, '');
      expect(conditional.headers['etag'], [tag]);
      // Content headers are dropped on a 304 (RFC 9110 §15.4.5).
      expect(conditional.headers.containsKey('content-type'), isFalse);
    });

    test('a non-matching If-None-Match still returns 200 + etag', () async {
      final r = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': '"nope"'}),
        Response.text('hi'),
      );
      expect(r.status, 200);
      expect(r.headers.containsKey('etag'), isTrue);
    });

    test('* matches any current representation', () async {
      final r = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': '*'}),
        Response.text('hi'),
      );
      expect(r.status, 304);
    });

    test('a comma-separated list matches any member', () async {
      final tag = (await run(
        etag(),
        testContext(newEnv()),
        Response.text('hi'),
      )).headers['etag']!.single;
      final r = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': '"x", $tag, "y"'}),
        Response.text('hi'),
      );
      expect(r.status, 304);
    });

    test('weak comparison ignores a W/ prefix', () async {
      final tag = (await run(
        etag(),
        testContext(newEnv()),
        Response.text('hi'),
      )).headers['etag']!.single;
      final r = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': 'W/$tag'}),
        Response.text('hi'),
      );
      expect(r.status, 304);
    });

    test('a stream body passes through untouched', () async {
      final r = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': '*'}),
        Response(200, body: Stream.value(utf8.encode('hi'))),
      );
      expect(r.status, 200);
      expect(r.headers.containsKey('etag'), isFalse);
      expect(r.body, isA<Stream<List<int>>>());
    });

    test('a non-GET/HEAD gets the etag but never a 304', () async {
      final tag = (await run(
        etag(),
        testContext(newEnv()),
        Response.text('hi'),
      )).headers['etag']!.single;
      final r = await run(
        etag(),
        testContext(newEnv(), method: 'POST', headers: {'if-none-match': tag}),
        Response.text('hi'),
      );
      expect(r.status, 200);
      expect(r.headers['etag'], [tag]);
    });

    test('a non-200 is left untagged', () async {
      final r = await run(
        etag(),
        testContext(newEnv()),
        Response(201, body: 'created'),
      );
      expect(r.headers.containsKey('etag'), isFalse);
    });

    test('a handler-supplied etag is respected, not overwritten', () async {
      final r = await run(
        etag(),
        testContext(newEnv(), headers: {'if-none-match': '"app"'}),
        Response(
          200,
          headers: {
            'etag': const ['"app"'],
          },
          body: 'hi',
        ),
      );
      expect(r.status, 304);
      expect(r.headers['etag'], ['"app"']);
    });
  });

  group('gzip', () {
    final big = 'x' * 2000;

    test('round-trips: the compressed body decodes to the original', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response.text(big),
      );
      expect(r.headers['content-encoding'], ['gzip']);
      expect(r.headers['vary'], contains('Accept-Encoding'));
      final body = r.body as List<int>;
      expect(utf8.decode(io.gzip.decode(body)), big);
    });

    test('gzip;q=0 skips compression but still Varies', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip;q=0'}),
        Response.text(big),
      );
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.headers['vary'], contains('Accept-Encoding'));
      expect(r.body, big);
    });

    test('a body below the threshold is left uncompressed', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response.text('small'),
      );
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.headers['vary'], contains('Accept-Encoding'));
      expect(r.body, 'small');
    });

    test('Vary is unioned with an existing Vary value', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response(
          200,
          headers: {
            'vary': const ['Origin'],
          },
          body: big,
        ),
      );
      expect(r.headers['vary'], ['Origin', 'Accept-Encoding']);
    });

    test('a stream body passes through untouched (no Vary)', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response(200, body: Stream.value(utf8.encode(big))),
      );
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.headers.containsKey('vary'), isFalse);
      expect(r.body, isA<Stream<List<int>>>());
    });

    test('a 204 is not compressed', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response(204, body: big),
      );
      expect(r.headers.containsKey('content-encoding'), isFalse);
    });

    test('an already-encoded body is not re-compressed', () async {
      final r = await run(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response(
          200,
          headers: {
            'content-encoding': const ['br'],
          },
          body: big,
        ),
      );
      expect(r.headers['content-encoding'], ['br']);
    });

    test('no accept-encoding skips compression but still Varies', () async {
      final r = await run(gzip(), testContext(newEnv()), Response.text(big));
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.headers['vary'], contains('Accept-Encoding'));
    });
  });

  group('composed stack (gzip outer, etag inner)', () {
    final big = 'y' * 2000;

    Future<Response> stack(Context<Env> c, Response handler) async =>
        gzip<Env>()(c, (c2) => etag<Env>()(c2, (_) => handler));

    test(
      'etag over identity body, gzip encodes; both headers present',
      () async {
        final r = await stack(
          testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
          Response.text(big),
        );
        expect(r.status, 200);
        expect(r.headers['content-encoding'], ['gzip']);
        expect(r.headers.containsKey('etag'), isTrue);
        expect(r.headers['vary'], contains('Accept-Encoding'));
        expect(utf8.decode(io.gzip.decode(r.body as List<int>)), big);
      },
    );

    test('a conditional request 304s and drops the body', () async {
      // The etag is computed pre-encoding, so it is stable regardless of gzip.
      final tag = (await stack(
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        Response.text(big),
      )).headers['etag']!.single;

      final r = await stack(
        testContext(
          newEnv(),
          headers: {'accept-encoding': 'gzip', 'if-none-match': tag},
        ),
        Response.text(big),
      );
      expect(r.status, 304);
      expect(r.body, '');
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.headers['etag'], [tag]);
    });
  });

  group('gzip + Content-Length framing (socket)', () {
    test('the wire Content-Length equals the compressed byte count', () async {
      final big = 'z' * 4000;
      final app = App<Env>()..use(gzip());
      app.get('/big', (c) => c.text(big));
      final server = await app.serve(boot, port: 8123);

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, 8123);
      socket.write(
        'GET /big HTTP/1.1\r\nHost: x\r\n'
        'Accept-Encoding: gzip\r\nConnection: close\r\n\r\n',
      );
      await socket.flush();
      final received = <int>[];
      await socket.forEach(received.addAll);
      socket.destroy();

      // Split headers from body on the CRLFCRLF boundary.
      const sep = [13, 10, 13, 10];
      var split = -1;
      for (var i = 0; i + 3 < received.length; i++) {
        if (received[i] == sep[0] &&
            received[i + 1] == sep[1] &&
            received[i + 2] == sep[2] &&
            received[i + 3] == sep[3]) {
          split = i;
          break;
        }
      }
      expect(split, greaterThan(0));
      final head = ascii.decode(received.sublist(0, split)).toLowerCase();
      final body = received.sublist(split + 4);

      expect(head, contains('content-encoding: gzip'));
      expect(head, isNot(contains('transfer-encoding')));
      final match = RegExp(r'content-length: (\d+)').firstMatch(head);
      expect(match, isNotNull);
      expect(int.parse(match!.group(1)!), body.length);
      // The framed bytes are exactly the gzip stream, and decode to the source.
      expect(utf8.decode(io.gzip.decode(body)), big);

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });
  });
}
