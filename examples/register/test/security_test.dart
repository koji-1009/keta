/// Security is enforced by the runtime gate, not just documented: middleware
/// ordering (a throw below recover still carries CORS headers), the
/// bearer/apiKey declarations (401 vs 403, public vs default, verifier→
/// principal handoff), and the CORS preflight plus apiKey-gated metrics
/// endpoint that ride on the same stack.
library;

import 'package:keta/test.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_register_example/app.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('the middleware order holds', () {
    // Everything that throws must sit below recover, and everything that
    // decorates a response above it. Get that wrong and the failure is quiet:
    // the status is right and the headers a browser needs are missing, so the
    // client reports an opaque CORS error rather than the status it was sent.
    //
    // timeout is the one that catches people out. It does not return a 504, it
    // throws GatewayTimeout — so with recover below it, `chain` skips cors's
    // header callback on the way out and only App._fallback renders the
    // response. A 401 does not exercise this at all (enforceSecurity sits below
    // recover either way), which is why this drives the deadline instead.
    test('a timed-out request still carries CORS headers', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final app = buildApp(requestTimeout: const Duration(milliseconds: 20))
        ..get(
          '/slow',
          (c) async {
            await Future<void>.delayed(const Duration(seconds: 1));
            return c.text('too late');
          },
          doc: const RouteDoc(
            success: Success(),
            summary: 'Deliberately slow',
            security: [],
          ),
        );

      final r = await TestClient(
        app,
        env,
      ).get('/slow', headers: const {'origin': 'https://app.example.com'});
      expect(r.status, 504);
      expect(
        r.headers['access-control-allow-origin'],
        '*',
        reason:
            'a 504 without CORS headers reaches the browser as a network '
            'error, so the client cannot tell a timeout from an outage',
      );
    });
  });

  group('the security declarations are enforced, not decorative', () {
    test('no credentials is 401, and a bad token is too', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);

      // /users declares no security, so it inherits the secure-by-default
      // global. Forgetting to think about auth fails closed.
      expect((await client.get('/users')).status, 401);
      expect(
        (await client.get(
          '/users',
          headers: const {'authorization': 'Bearer nope'},
        )).status,
        401,
      );
      // Wrong scheme for the route: /metrics wants apiKey, not bearer.
      expect((await client.get('/metrics', headers: admin)).status, 401);
    });

    test('an explicitly public route needs nothing', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      // `security: []`, not "no declaration" — the difference is the whole
      // point of the override.
      expect((await client.get('/health')).status, 200);
    });

    test('the verifier hands the principal to the handler', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      // /whoami reads c.get(principal), which only the bearer verifier sets.
      expect((await client.get('/whoami', headers: admin)).json(), {
        'id': 'ada',
        'admin': true,
      });
      expect((await client.get('/whoami', headers: user)).json(), {
        'id': 'bo',
        'admin': false,
      });
    });

    test('authentication is not authorization', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      // Both tokens authenticate. Only one is an admin: 401 says "who are
      // you", 403 says "not you".
      expect((await client.get('/admin/ping', headers: admin)).status, 200);
      expect((await client.get('/admin/ping', headers: user)).status, 403);
      expect((await client.get('/admin/ping')).status, 401);
    });

    test('the document says exactly what the gate does', () {
      final doc = buildOpenApi().toJson();
      Map<String, Object?> op(String path, [String verb = 'get']) =>
          ((doc['paths'] as Map)[path] as Map)[verb] as Map<String, Object?>;

      // Public: no security, and no 401 promised.
      expect(op('/health').containsKey('security'), isFalse);
      expect((op('/health')['responses'] as Map).containsKey('401'), isFalse);
      // Inherits the default.
      expect(op('/users')['security'], [
        {'bearer': <String>[]},
      ]);
      // Overrides it with a different scheme.
      expect(op('/metrics')['security'], [
        {'apiKey': <String>[]},
      ]);
      // Both schemes reached components, carried as data by the declarations.
      expect(
        ((doc['components'] as Map)['securitySchemes'] as Map).keys,
        unorderedEquals(['bearer', 'apiKey']),
      );
    });
  });

  test('CORS preflight and the metrics endpoint work', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    // A preflight is OPTIONS carrying access-control-request-method (keta's
    // cors() contract); a plain OPTIONS falls through to the route instead,
    // where /users' declared security would 401 it.
    final preflight = await client.options(
      '/users',
      headers: const {'access-control-request-method': 'GET'},
    );
    expect(preflight.status, 204);
    expect(preflight.headers['access-control-allow-origin'], '*');

    await client.get('/users/999', headers: admin); // record a request
    expect(
      (await client.get(
        '/metrics',
        headers: const {'x-api-key': 'k-metrics'},
      )).text(),
      contains('keta_requests_total'),
    );
  });
}
