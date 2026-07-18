/// Two ways to authenticate against the same `enforceSecurity` gate: a bearer
/// token guarding `/admin` (plus its own role check, 403 on top of 401), and a
/// cookie session minted by `/login` and spent by `/me`/`/logout`. Both
/// declarations drive the same OpenAPI output the runtime gate enforces.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_auth_example/app.dart';
import 'package:keta_auth_example/auth.dart';
import 'package:keta_auth_example/env.dart';
import 'package:test/test.dart';

TestClient<Env> newClient() =>
    TestClient(buildApp(), Env(StdoutLog(flushInterval: Duration.zero)));

void main() {
  group('runtime gate (enforceSecurity)', () {
    test('a public route needs no token', () async {
      expect((await newClient().get('/public')).text(), 'anyone can read this');
    });

    test('a route that declares nothing fails closed, not open', () async {
      // The policy's `defaults: [bearer]` applies to any route whose RouteDoc
      // omits `security` (or that carries no RouteDoc at all) — forgetting to
      // think about auth is a 401, never a silently public route.
      final app = buildApp()
        ..get('/undeclared', (c) => c.text('should not be reachable'));
      final client = TestClient(
        app,
        Env(StdoutLog(flushInterval: Duration.zero)),
      );
      expect((await client.get('/undeclared')).status, 401);
    });

    test('the declared route enforces auth (401) and role (403)', () async {
      final client = newClient();

      // No token → 401 (enforceSecurity, from the route's declared bearer).
      expect((await client.get('/admin/whoami')).status, 401);
      // Authenticated but wrong role → 403 (the app's role guard).
      expect(
        (await client.get(
          '/admin/whoami',
          headers: {'authorization': 'Bearer member-token'},
        )).status,
        403,
      );
      // Admin token → 200 with the resolved role.
      final ok = await client.get(
        '/admin/whoami',
        headers: {'authorization': 'Bearer admin-token'},
      );
      expect(ok.status, 200);
      expect(ok.json(), {'role': 'admin'});
    });

    test(
      'requireRole 403s when no role was ever set, not 500 (tryGet, not get)',
      () async {
        // Bypasses enforceSecurity entirely, so authRole is genuinely unset —
        // exercising requireRole's own contract in isolation from whichever
        // verifier normally sets it. Before the tryGet fix this reached
        // c.get(authRole) and threw StateError → 500; an absent principal is
        // an expected auth outcome (403 here), never a crash.
        final app = App<Env>()..use(recover());
        app.group('/x')
          ..use(requireRole('admin'))
          ..get('/y', (c) => c.text('should not be reachable'));
        final client = TestClient(
          app,
          Env(StdoutLog(flushInterval: Duration.zero)),
        );
        expect((await client.get('/x/y')).status, 403);
      },
    );
  });

  group('cookie session (/login, /me, /logout)', () {
    test('correct credentials 200 with a well-formed Set-Cookie', () async {
      final res = await newClient().post(
        '/login',
        json: {'username': 'admin', 'password': 'admin-pass'},
      );
      expect(res.status, 200);
      expect(res.json(), {'role': 'admin'});
      final setCookie = res.headers['set-cookie'];
      expect(setCookie, isNotNull);
      expect(setCookie, contains('sid='));
      expect(setCookie, contains('HttpOnly'));
      expect(setCookie, contains('SameSite=Lax'));
      // secure: true is deliberately not set on this http-only demo (a
      // browser drops a Secure cookie sent over plain HTTP outright); a
      // production deployment over TLS must add it.
      expect(setCookie, isNot(contains('Secure')));
    });

    test('wrong credentials: 401 and no Set-Cookie', () async {
      final res = await newClient().post(
        '/login',
        json: {'username': 'admin', 'password': 'wrong'},
      );
      expect(res.status, 401);
      expect(res.headers.containsKey('set-cookie'), isFalse);
    });

    test('/me: 200 with the cookie, 401 without', () async {
      final client = newClient();
      final login = await client.post(
        '/login',
        json: {'username': 'member', 'password': 'member-pass'},
      );
      final sid = _sidFrom(login.headers['set-cookie']!);

      final withCookie = await client.get(
        '/me',
        headers: {'cookie': 'sid=$sid'},
      );
      expect(withCookie.status, 200);
      expect(withCookie.json(), {'role': 'member'});

      expect((await client.get('/me')).status, 401);
    });

    test('logout ends the session: the old sid then 401s on /me', () async {
      final client = newClient();
      final login = await client.post(
        '/login',
        json: {'username': 'admin', 'password': 'admin-pass'},
      );
      final sid = _sidFrom(login.headers['set-cookie']!);
      final cookieHeader = {'cookie': 'sid=$sid'};

      expect((await client.get('/me', headers: cookieHeader)).status, 200);

      final out = await client.post('/logout', headers: cookieHeader);
      expect(out.status, 200);

      expect((await client.get('/me', headers: cookieHeader)).status, 401);
    });
  });

  group('openapi conformance', () {
    test('the same declaration drives the OpenAPI output', () {
      final doc = buildOpenApi().toJson();
      final op =
          ((doc['paths'] as Map)['/admin/whoami'] as Map)['get']
              as Map<String, Object?>;
      expect(op['security'], [
        {'bearer': <String>[]},
      ]);
      expect((op['responses'] as Map).containsKey('401'), isTrue);
      final securitySchemes =
          (doc['components'] as Map)['securitySchemes'] as Map;
      expect(securitySchemes['bearer'], {'type': 'http', 'scheme': 'bearer'});
      // /public declares no security → no security key, no auto-401.
      final pub =
          ((doc['paths'] as Map)['/public'] as Map)['get']
              as Map<String, Object?>;
      expect(pub.containsKey('security'), isFalse);

      // The cookie session flow declares its own security, the same as the
      // bearer flow: /login is public (it is how a caller becomes
      // authenticated), /me and /logout require the cookie scheme.
      final login =
          ((doc['paths'] as Map)['/login'] as Map)['post']
              as Map<String, Object?>;
      expect(login.containsKey('security'), isFalse);

      final me =
          ((doc['paths'] as Map)['/me'] as Map)['get'] as Map<String, Object?>;
      expect(me['security'], [
        {'cookieAuth': <String>[]},
      ]);
      expect((me['responses'] as Map).containsKey('401'), isTrue);

      final logout =
          ((doc['paths'] as Map)['/logout'] as Map)['post']
              as Map<String, Object?>;
      expect(logout['security'], [
        {'cookieAuth': <String>[]},
      ]);

      expect(securitySchemes['cookieAuth'], {
        'type': 'apiKey',
        'in': 'cookie',
        'name': 'sid',
      });
    });
  });
}

/// Pulls the `sid` value out of a `Set-Cookie` header value, e.g.
/// `sid=abc123; Max-Age=3600; HttpOnly; SameSite=Lax` → `abc123`.
String _sidFrom(String setCookie) =>
    RegExp(r'sid=([^;]+)').firstMatch(setCookie)!.group(1)!;
