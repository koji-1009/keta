/// Owns the cors() middleware: the wildcard origin's short-circuit and
/// preflight method/header lists, the specific-origin Vary: Origin union that
/// dedups case-insensitively rather than blindly appending, the Vary: Origin a
/// *disallowed* origin still carries (cache-poisoning otherwise), and the
/// construction-time rejection of `'*'` + credentials the Fetch spec forbids.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('cors wildcard', () {
    test('answers any origin with * and custom method/header lists', () async {
      final app = App<Env>()
        ..use(
          cors(
            allowOrigins: ['*'],
            allowMethods: ['GET', 'PUT'],
            allowHeaders: ['x-custom'],
          ),
        );
      app.get('/x', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      // An actual response carries the allowed origin; the method/header lists
      // are preflight-only (they have no meaning on a non-preflight response).
      final r = await client.get(
        '/x',
        headers: {'origin': 'https://any.example'},
      );
      expect(r.headers['access-control-allow-origin'], '*');
      expect(r.headers.containsKey('access-control-allow-methods'), isFalse);

      // The wildcard short-circuits, so even a request with no Origin is allowed.
      final noOrigin = await client.get('/x');
      expect(noOrigin.headers['access-control-allow-origin'], '*');

      // A real preflight (OPTIONS + access-control-request-method) gets 204 and
      // the custom method/header lists.
      final pre = await client.options(
        '/x',
        headers: {'access-control-request-method': 'PUT'},
      );
      expect(pre.status, 204);
      expect(pre.headers['access-control-allow-origin'], '*');
      expect(pre.headers['access-control-allow-methods'], 'GET, PUT');
      expect(pre.headers['access-control-allow-headers'], 'x-custom');
    });
  });

  group('cors specific origin — Vary union', () {
    // A specific (non-`*`) origin always adds `Vary: Origin` (shared-cache
    // poisoning otherwise). gzip's own Vary union dedups case-insensitively
    // (`_varyAcceptEncoding`); cors must match that discipline rather than
    // blindly appending, which would double `Origin` when a handler (or an
    // upstream middleware) already set it.
    test('does not duplicate a Vary: Origin the handler already set', () async {
      final mw = cors<Env>(allowOrigins: ['https://example.com']);
      final c = testContext(
        newEnv(),
        headers: {'origin': 'https://example.com'},
      );
      final r = await mw(
        c,
        (_) => Response.text(
          'ok',
          headers: {
            'vary': ['Origin'],
          },
        ),
      );
      expect(r.headers['vary'], ['Origin']);
    });

    test('unions with an unrelated existing Vary value', () async {
      final mw = cors<Env>(allowOrigins: ['https://example.com']);
      final c = testContext(
        newEnv(),
        headers: {'origin': 'https://example.com'},
      );
      final r = await mw(
        c,
        (_) => Response.text(
          'ok',
          headers: {
            'vary': ['Accept-Encoding'],
          },
        ),
      );
      expect(r.headers['vary'], ['Accept-Encoding', 'Origin']);
    });

    test('dedup is case-insensitive', () async {
      final mw = cors<Env>(allowOrigins: ['https://example.com']);
      final c = testContext(
        newEnv(),
        headers: {'origin': 'https://example.com'},
      );
      final r = await mw(
        c,
        (_) => Response.text(
          'ok',
          headers: {
            'vary': ['origin'],
          },
        ),
      );
      expect(r.headers['vary'], ['origin']);
    });
  });

  group('cors disallowed origin still Varies', () {
    // A response to a *rejected* origin carries no access-control-allow-origin,
    // but it must still carry `Vary: Origin`: otherwise a shared cache could
    // store this header-less response and later serve it to an allowed origin,
    // which would then see no allow-origin header at all.
    test(
      'actual response to a disallowed origin has Vary but no ACAO',
      () async {
        final mw = cors<Env>(allowOrigins: ['https://example.com']);
        final r = await mw(
          testContext(newEnv(), headers: {'origin': 'https://evil.example'}),
          (_) => Response.text('ok'),
        );
        expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
        expect(r.headers['vary'], ['Origin']);
      },
    );

    test('the disallowed Vary still unions over an existing Vary', () async {
      final mw = cors<Env>(allowOrigins: ['https://example.com']);
      final r = await mw(
        testContext(newEnv(), headers: {'origin': 'https://evil.example'}),
        (_) => Response.text(
          'ok',
          headers: {
            'vary': ['Accept-Encoding'],
          },
        ),
      );
      expect(r.headers['vary'], ['Accept-Encoding', 'Origin']);
    });

    test(
      'a request with no Origin header still Varies (origin-specific config)',
      () async {
        final mw = cors<Env>(allowOrigins: ['https://example.com']);
        final r = await mw(testContext(newEnv()), (_) => Response.text('ok'));
        expect(r.headers.containsKey('access-control-allow-origin'), isFalse);
        expect(r.headers['vary'], ['Origin']);
      },
    );

    test(
      'a preflight from a disallowed origin is 204 with Vary, no ACAO',
      () async {
        final app = App<Env>()
          ..use(cors(allowOrigins: ['https://example.com']));
        app.get('/x', (c) => c.text('ok'));
        final client = TestClient(app, newEnv());
        final pre = await client.options(
          '/x',
          headers: {
            'origin': 'https://evil.example',
            'access-control-request-method': 'GET',
          },
        );
        expect(pre.status, 204);
        expect(pre.headers.containsKey('access-control-allow-origin'), isFalse);
        expect(pre.headers['vary'], 'Origin');
      },
    );

    test('the wildcard needs no Vary (origin-independent)', () async {
      final mw = cors<Env>(allowOrigins: ['*']);
      final r = await mw(
        testContext(newEnv(), headers: {'origin': 'https://any.example'}),
        (_) => Response.text('ok'),
      );
      expect(r.headers['access-control-allow-origin'], ['*']);
      expect(r.headers.containsKey('vary'), isFalse);
    });
  });

  group('cors credentials', () {
    // The Fetch spec forbids `Access-Control-Allow-Origin: *` together with
    // credentials; the pair is refused loudly at construction, like every other
    // authoring defect in this framework.
    test("'*' + allowCredentials throws at construction", () {
      expect(
        () => cors<Env>(allowOrigins: ['*'], allowCredentials: true),
        throwsArgumentError,
      );
    });

    test(
      'a specific origin + credentials is allowed and echoes both',
      () async {
        final mw = cors<Env>(
          allowOrigins: ['https://example.com'],
          allowCredentials: true,
        );
        final r = await mw(
          testContext(newEnv(), headers: {'origin': 'https://example.com'}),
          (_) => Response.text('ok'),
        );
        expect(r.headers['access-control-allow-origin'], [
          'https://example.com',
        ]);
        expect(r.headers['access-control-allow-credentials'], ['true']);
        expect(r.headers['vary'], ['Origin']);
      },
    );
  });
}
