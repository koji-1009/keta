/// `requestedUri` reconstruction from the `Host` header on the way through
/// `shelfToKeta`: query-string round-tripping and hardening against a
/// malformed or hostile `Host` header smuggling extra URI components.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_shelf/keta_shelf.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

class Env {}

void main() {
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

    test('rejects a Host header smuggling a path as 400', () async {
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
      ).get('/token', headers: {'host': 'evil.com/inject'});
      expect(res.status, 400);
    });
  });
}
