/// Owns the two gates at the edge of the core where "the semantic layer
/// accepts it" and "the wire accepts it" have to agree: response headers, and
/// a request path the URI decoder cannot decode.
///
/// Both are pinned over a real socket, because both failed in ways that only a
/// socket shows. A header the wire refuses does not surface as an error to the
/// handler that built it — the response write throws, the transport's defensive
/// catch frames a bare 500, and the client is handed `200 OK` with an empty
/// body. A malformed percent-escape escaped dispatch entirely, so what a test
/// saw and what a client got were different things.
@TestOn('vm')
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

void main() {
  group('response header gate', () {
    test('a non-ASCII header value is refused at construction', () {
      // Reachable from ordinary data: echoing a display name into a header.
      // Accepted, it emptied the response for every user whose name is not
      // ASCII — a silent data-loss path driven by user input.
      expect(
        () => Response(
          200,
          headers: {
            'x-user-name': ['José'],
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a header name that is not a token is refused', () {
      for (final name in ['x bad', 'x:bad', 'x(bad)', 'x@bad', '']) {
        expect(
          () => Response(
            200,
            headers: {
              name: ['v'],
            },
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'header name "$name" is not an RFC 9110 token',
        );
      }
    });

    test('CRLF is still refused — the response-splitting primitive', () {
      expect(
        () => Response(
          200,
          headers: {
            'x-a': ['a\r\nb'],
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('printable ASCII, SP and HTAB are accepted', () {
      final r = Response(
        200,
        headers: {
          'x-a': ['plain value, with punctuation: /?=[]{}'],
          'x-b': ['tab\there'],
        },
      );
      expect(r.headers['x-a'], ['plain value, with punctuation: /?=[]{}']);
      expect(r.headers['x-b'], ['tab\there']);
    });

    test('copyWith applies the same gate on both replace and merge', () {
      final base = Response(
        200,
        headers: {
          'x-a': ['ok'],
        },
      );
      expect(
        () => base.copyWith(
          headers: {
            'x-a': ['José'],
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => base.copyWith(
          addHeaders: {
            'x-b': ['José'],
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'what the gate accepts, the wire delivers with its body intact',
      () async {
        // The assertion the old gate could not make. A value the semantic layer
        // accepted and the transport refused produced `200 OK` with
        // `content-length: 0` — the handler's body gone, no error anywhere the
        // handler could see. Nothing may pass here that cannot be written.
        final app = App<Object?>()
          ..use(recover())
          ..get(
            '/echo',
            (c) => c.text(
              'body-intact',
              headers: {
                'x-name': ['plain-ascii'],
              },
            ),
          );
        final server = await TestServer.start(app, null);
        addTearDown(server.close);

        final raw = await server.sendRaw(
          'GET /echo HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
        );
        expect(TestServer.statusOf(raw), 200);
        expect(raw, contains('body-intact'));
        expect(raw, contains('x-name: plain-ascii'));
      },
    );
  });

  group('malformed percent-encoding in the path', () {
    late TestServer server;

    setUp(() async {
      final app = App<Object?>()
        ..use(recover())
        ..get('/ok', (c) => c.text('ok'));
      server = await TestServer.start(app, null);
    });
    tearDown(() => server.close());

    test('is a 400, not a 500', () async {
      // `%c0%af` is an overlong encoding of '/': not valid UTF-8, so the lazy
      // decode inside `uri.pathSegments` throws. It used to escape dispatch —
      // past `recover()` and past the core's own last-resort fallback — and
      // land in the transport's defensive catch as a 500 with a stack trace on
      // every hit, which is a free way to flood the log ring.
      final raw = await server.sendRaw(
        'GET /%c0%af HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
      );
      expect(TestServer.statusOf(raw), 400);
      expect(raw, contains('malformed percent-encoding'));
    });

    test('leaves the server serving', () async {
      for (var i = 0; i < 3; i++) {
        await server.sendRaw(
          'GET /%ff%fe HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
        );
      }
      final after = await server.sendRaw(
        'GET /ok HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
      );
      expect(TestServer.statusOf(after), 200);
    });

    test('a well-formed escape still decodes and matches', () async {
      final app = App<Object?>()
        ..get('/users/:id', (c) => c.text(c.param<String>('id')));
      final other = await TestServer.start(app, null);
      addTearDown(other.close);

      // `%20` is a legal escape for a space: it must decode, not be refused.
      final raw = await other.sendRaw(
        'GET /users/a%20b HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
      );
      expect(TestServer.statusOf(raw), 200);
      expect(raw, contains('a b'));
    });
  });
}
