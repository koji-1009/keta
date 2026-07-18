import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_shelf/keta_shelf.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

class Env {}

class _FakeConnInfo implements HttpConnectionInfo {
  _FakeConnInfo(this.remoteAddress);
  @override
  final InternetAddress remoteAddress;
  @override
  int get remotePort => 0;
  @override
  int get localPort => 0;
}

void main() {
  test('ketaToShelf serves a keta app as a shelf handler', () async {
    final app = App<Env>()..use(recover());
    app.get('/hello/:who', (c) => c.json({'hello': c.param<String>('who')}));

    final handler = ketaToShelf(app, Env());
    final response = await handler(
      shelf.Request('GET', Uri.parse('http://localhost/hello/shelf')),
    );

    expect(response.statusCode, 200);
    expect(await response.readAsString(), '{"hello":"shelf"}');
  });

  test('ketaToShelf maps a keta 404 through', () async {
    final handler = ketaToShelf(App<Env>(), Env());
    final response = await handler(
      shelf.Request('GET', Uri.parse('http://localhost/nope')),
    );
    expect(response.statusCode, 404);
  });

  test('ketaToShelf rejects a Response.upgrade loudly (no socket)', () async {
    // shelf hands no socket across this bridge, so an upgrade route cannot be
    // served through it. It must fail loudly — a StateError — rather than
    // mis-frame a bodyless 101 onto the wire that no client could use.
    final app = App<Env>();
    app.get('/ws', (c) => Response.upgrade((channel) => channel.close()));
    final handler = ketaToShelf(app, Env());

    await expectLater(
      handler(shelf.Request('GET', Uri.parse('http://localhost/ws'))),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('cannot switch protocols'),
        ),
      ),
    );
  });

  test('shelfToKeta runs a shelf handler inside a keta route', () async {
    shelf.Response shelfHandler(shelf.Request request) =>
        shelf.Response.ok('hi from shelf via ${request.method}');

    final app = App<Env>();
    app.get('/bridge', shelfToKeta(shelfHandler));
    final client = TestClient(app, Env());

    final res = await client.get('/bridge');
    expect(res.status, 200);
    expect(res.text(), 'hi from shelf via GET');
  });

  test('shelfToKeta forwards the request body', () async {
    Future<shelf.Response> echo(shelf.Request request) async =>
        shelf.Response.ok('echo:${await request.readAsString()}');

    final app = App<Env>();
    app.post('/echo', shelfToKeta(echo));
    final client = TestClient(app, Env());

    final res = await client.post('/echo', json: {'a': 1});
    expect(res.text(), 'echo:{"a":1}');
  });

  group('ketaToShelf', () {
    test('passes keta response headers through', () async {
      final app = App<Env>();
      app.get(
        '/h',
        (c) => Response(
          201,
          headers: {
            'x-keta': ['yes'],
            'content-type': ['text/plain'],
          },
          body: 'ok',
        ),
      );
      final response = await ketaToShelf(app, Env())(
        shelf.Request('GET', Uri.parse('http://localhost/h')),
      );
      expect(response.statusCode, 201);
      expect(response.headers['x-keta'], 'yes');
      expect(response.headers['content-type'], 'text/plain');
    });

    test('serves a List<int> keta body', () async {
      final app = App<Env>();
      app.get('/bytes', (c) => Response(200, body: utf8.encode('bytes!')));
      final response = await ketaToShelf(app, Env())(
        shelf.Request('GET', Uri.parse('http://localhost/bytes')),
      );
      expect(await response.readAsString(), 'bytes!');
    });

    test('serves a Stream<List<int>> keta body', () async {
      final app = App<Env>();
      app.get(
        '/stream',
        (c) => Response(
          200,
          body: Stream<List<int>>.fromIterable([
            utf8.encode('a'),
            utf8.encode('b'),
          ]),
        ),
      );
      final response = await ketaToShelf(app, Env())(
        shelf.Request('GET', Uri.parse('http://localhost/stream')),
      );
      expect(await response.readAsString(), 'ab');
    });

    test('forwards the shelf request body to keta', () async {
      final app = App<Env>();
      app.post(
        '/echo',
        (c) async => c.text('got:${utf8.decode(await c.bodyBytes())}'),
      );
      final response = await ketaToShelf(app, Env())(
        shelf.Request(
          'POST',
          Uri.parse('http://localhost/echo'),
          body: 'payload',
        ),
      );
      expect(await response.readAsString(), 'got:payload');
    });

    test(
      'enforces maxBodyBytes as a 413, allowing the exact boundary',
      () async {
        final app = App<Env>();
        app.post(
          '/upload',
          (c) async => c.text('len=${(await c.bodyBytes()).length}'),
        );
        final handler = ketaToShelf(app, Env(), maxBodyBytes: 4);

        final ok = await handler(
          shelf.Request(
            'POST',
            Uri.parse('http://localhost/upload'),
            body: 'abcd',
          ),
        );
        expect(ok.statusCode, 200);
        expect(await ok.readAsString(), 'len=4');

        final tooBig = await handler(
          shelf.Request(
            'POST',
            Uri.parse('http://localhost/upload'),
            body: 'way too big',
          ),
        );
        expect(tooBig.statusCode, 413);
        expect(await tooBig.readAsString(), contains('exceeds 4 bytes'));
      },
    );

    test('fails fast on route conflicts at compile time', () {
      final app = App<Env>();
      app.get('/a/:x', (c) => c.text('1'));
      app.get('/a/:y', (c) => c.text('2'));
      expect(
        () => ketaToShelf(app, Env()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('route conflict'),
          ),
        ),
      );
    });

    test('lowercases shelf request headers for keta', () async {
      final app = App<Env>();
      app.get(
        '/hdr',
        (c) => c.text(
          '${c.header('x-trace-id')}|${c.headers.containsKey('x-trace-id')}',
        ),
      );
      final response = await ketaToShelf(app, Env())(
        shelf.Request(
          'GET',
          Uri.parse('http://localhost/hdr'),
          headers: {'X-Trace-Id': 'abc'},
        ),
      );
      expect(await response.readAsString(), 'abc|true');
    });
  });

  group('shelfToKeta', () {
    test('passes a null body for an empty request body', () async {
      Future<shelf.Response> probe(shelf.Request request) async =>
          shelf.Response.ok('empty=${(await request.readAsString()).isEmpty}');
      final app = App<Env>();
      app.get('/empty', shelfToKeta(probe));
      final res = await TestClient(app, Env()).get('/empty');
      expect(res.status, 200);
      expect(res.text(), 'empty=true');
    });

    test('maps a non-200 shelf status through', () async {
      final app = App<Env>();
      app.get(
        '/teapot',
        shelfToKeta((request) => shelf.Response(418, body: 'short and stout')),
      );
      final res = await TestClient(app, Env()).get('/teapot');
      expect(res.status, 418);
      expect(res.text(), 'short and stout');
    });

    test('passes response headers through and strips content-length', () async {
      final app = App<Env>();
      app.get(
        '/hdrs',
        shelfToKeta(
          (request) =>
              shelf.Response(200, body: 'hi', headers: {'x-shelf': 'v1'}),
        ),
      );
      final res = await TestClient(app, Env()).get('/hdrs');
      expect(res.headers['x-shelf'], 'v1');
      // shelf sets content-length automatically; the bridge must remove it so
      // the transport frames the body itself.
      expect(res.headers.containsKey('content-length'), isFalse);
      expect(res.text(), 'hi');
    });

    test('collects a multi-chunk streaming shelf body', () async {
      final app = App<Env>();
      app.get(
        '/chunks',
        shelfToKeta(
          (request) => shelf.Response(
            200,
            body: Stream<List<int>>.fromIterable([
              utf8.encode('one'),
              utf8.encode('-'),
              utf8.encode('two'),
            ]),
          ),
        ),
      );
      final res = await TestClient(app, Env()).get('/chunks');
      expect(res.status, 200);
      expect(res.text(), 'one-two');
    });

    test('forwards keta request headers to the shelf handler', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta(
          (request) => shelf.Response.ok('token=${request.headers['x-token']}'),
        ),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'X-Token': 'secret'});
      expect(res.text(), 'token=secret');
    });
  });

  group('_absolute (through the bridge)', () {
    test('keeps an already-absolute uri verbatim', () async {
      final app = App<Env>();
      app.get(
        '/inner',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final response = await ketaToShelf(app, Env())(
        shelf.Request('GET', Uri.parse('http://example.test:8080/inner?q=1')),
      );
      expect(
        await response.readAsString(),
        'http://example.test:8080/inner?q=1',
      );
    });

    test('preserves a non-empty query', () async {
      final app = App<Env>();
      app.get(
        '/q',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(app, Env()).get('/q?x=1&y=2');
      expect(res.text(), 'http://localhost/q?x=1&y=2');
    });

    test('omits the query separator when the query is empty', () async {
      final app = App<Env>();
      app.get(
        '/q',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(app, Env()).get('/q');
      expect(res.text(), 'http://localhost/q');
    });

    // A bare `?` (no key=value pairs) is a distinct request from no `?` at
    // all — Uri.hasQuery tells them apart even though uri.query is '' for
    // both. Losing the `?` on round-trip would silently rewrite the request
    // a shelf handler observes.
    test('preserves a bare query separator', () async {
      final app = App<Env>();
      app.get(
        '/q',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(app, Env()).get('/q?');
      expect(res.text(), 'http://localhost/q?');
    });

    // The `Host` header comes straight off the wire, unvalidated, so it can be
    // anything an attacker sends. A malformed value must fail the request
    // (400), not the process handling it (500).
    test(
      'rejects a malformed Host header as 400 (unterminated IPv6 bracket)',
      () async {
        final app = App<Env>();
        app.get(
          '/token',
          shelfToKeta(
            (request) => shelf.Response.ok(request.requestedUri.toString()),
          ),
        );
        final res = await TestClient(
          app,
          Env(),
        ).get('/token', headers: {'host': '[::1'});
        expect(res.status, 400);
      },
    );

    test('rejects a malformed Host header as 400 (invalid port)', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'host': 'host:abc'});
      expect(res.status, 400);
    });

    test('passes a valid IPv6 Host header through unchanged', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'host': '[::1]:8080'});
      expect(res.status, 200);
      expect(res.text(), 'http://[::1]:8080/token');
    });

    test('passes a valid host:port Host header through unchanged', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'host': 'host:8080'});
      expect(res.status, 200);
      expect(res.text(), 'http://host:8080/token');
    });

    // A Host header names an authority alone. `Uri.parse` will nonetheless
    // recover a query from `evil.com?inject=1` — and `Uri.replace(query:
    // null)` keeps the *base's* query rather than clearing it — so reflecting
    // the parsed Host wholesale would let this smuggle a query into
    // `requestedUri` that the client never put on the request line/path.
    test(
      'rejects a Host header smuggling a query as 400, not a reflected query',
      () async {
        final app = App<Env>();
        app.get(
          '/token',
          shelfToKeta(
            (request) => shelf.Response.ok(request.requestedUri.toString()),
          ),
        );
        final res = await TestClient(
          app,
          Env(),
        ).get('/token', headers: {'host': 'evil.com?inject=1'});
        expect(res.status, 400);
      },
    );

    test('rejects a Host header smuggling userInfo as 400', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'host': 'a@b.com'});
      expect(res.status, 400);
    });

    test('rejects a Host header smuggling a fragment as 400', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta(
          (request) => shelf.Response.ok(request.requestedUri.toString()),
        ),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'host': 'evil.com#frag'});
      expect(res.status, 400);
    });
  });

  group('_ShelfRequest.remoteAddress', () {
    Future<String> addrWith(Map<String, Object> context) async {
      final app = App<Env>();
      app.get('/ip', (c) => c.text('addr=[${c.remoteAddress}]'));
      final response = await ketaToShelf(app, Env())(
        shelf.Request(
          'GET',
          Uri.parse('http://localhost/ip'),
          context: context,
        ),
      );
      return response.readAsString();
    }

    test('is empty when no connection info is present', () async {
      expect(await addrWith({}), 'addr=[]');
    });

    test('reads the address off a HttpConnectionInfo', () async {
      expect(
        await addrWith({
          'shelf.io.connection_info': _FakeConnInfo(InternetAddress('9.9.9.9')),
        }),
        'addr=[9.9.9.9]',
      );
    });

    test('is empty when the value is not a HttpConnectionInfo', () async {
      expect(await addrWith({'shelf.io.connection_info': Object()}), 'addr=[]');
    });
  });

  group('framing and streaming', () {
    test('ketaToShelf drops a stale content-length on a stream body', () async {
      final app = App<Env>();
      app.get(
        '/s',
        (c) => Response(
          200,
          headers: {
            'content-length': ['999'],
          },
          body: Stream<List<int>>.value(utf8.encode('hi')),
        ),
      );
      final response = await ketaToShelf(app, Env())(
        shelf.Request('GET', Uri.parse('http://localhost/s')),
      );
      // The bogus 999 is gone; shelf frames the 2-byte body itself.
      expect(response.headers['content-length'], isNot('999'));
      expect(await response.readAsString(), 'hi');
    });

    test('shelfToKeta strips a capitalized Content-Length', () async {
      final app = App<Env>();
      app.get(
        '/h',
        shelfToKeta(
          (r) => shelf.Response(
            200,
            body: Stream<List<int>>.value(utf8.encode('hi')),
            headers: {'Content-Length': '999', 'x-k': 'v'},
          ),
        ),
      );
      final res = await TestClient(app, Env()).get('/h');
      expect(res.headers.containsKey('content-length'), isFalse);
      expect(res.headers['x-k'], 'v');
      expect(res.text(), 'hi');
    });

    test('shelfToKeta streams within maxBodyBytes and 413s past it', () async {
      Future<shelf.Response> echoLen(shelf.Request r) async =>
          shelf.Response.ok('len=${(await r.readAsString()).length}');

      // A generous limit lets a large body stream through to the shelf handler.
      final big = 'x' * ((1 << 20) + 100);
      final wide = App<Env>()
        ..post('/up', shelfToKeta(echoLen, maxBodyBytes: 1 << 21));
      final okRes = await TestClient(wide, Env()).post('/up', json: big);
      expect(okRes.status, 200);
      expect(okRes.text(), 'len=${big.length + 2}');

      // The limiter fails an over-limit read as a 413 stream error.
      final tight = App<Env>()
        ..post('/up', shelfToKeta(echoLen, maxBodyBytes: 4));
      final tooBig = await TestClient(tight, Env()).post('/up', json: 'abcd');
      expect(tooBig.status, 413); // "abcd" JSON-encodes to 6 bytes
    });

    test('shelfToKeta reflects the Host header into requestedUri', () async {
      final app = App<Env>();
      app.get(
        '/token',
        shelfToKeta((r) => shelf.Response.ok(r.requestedUri.toString())),
      );
      final res = await TestClient(
        app,
        Env(),
      ).get('/token', headers: {'host': 'api.example.com:8443'});
      expect(res.text(), 'http://api.example.com:8443/token');
    });

    test('ketaToShelf leaves bodyStream() unbounded (the escape hatch)', () async {
      final app = App<Env>();
      // A keta handler reading the bodyStream() escape gets the whole body; the
      // limit is enforced only at the core's buffering point (body/bodyBytes).
      app.post('/up', (c) async {
        final bytes = await c.bodyStream().expand((x) => x).toList();
        return c.text('len=${bytes.length}');
      });
      final handler = ketaToShelf(app, Env(), maxBodyBytes: 4);
      final res = await handler(
        shelf.Request(
          'POST',
          Uri.parse('http://localhost/up'),
          body: 'way too big',
        ),
      );
      expect(res.statusCode, 200);
      expect(await res.readAsString(), 'len=11');
    });
  });
}
