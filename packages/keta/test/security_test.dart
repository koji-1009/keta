/// `enforceSecurity`/`SecurityPolicy`: runtime enforcement of a route's
/// declared security — defaulting, explicit-public override, the secure-by-
/// default auth wall, synchronous and asynchronous verifiers, multi-scheme OR
/// (including a scheme with no registered verifier, which must be skipped,
/// not treated as a pass). This is the runtime gate; OpenApi.fromRoutes'
/// document-side security projection is covered in
/// openapi_generation_test.dart's "security" group.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

class Env {}

void main() {
  group('enforceSecurity', () {
    final verifiers = {
      'bearer': (Context<Env> c) => c.header('authorization') == 'Bearer ok',
    };

    App<Env> build(SecurityPolicy<Env> policy, void Function(App<Env>) routes) {
      final app = App<Env>()
        ..use(recover())
        ..use(enforceSecurity(policy));
      routes(app);
      return app;
    }

    test(
      'a public route (no declaration, empty default) is admitted',
      () async {
        final app = build(
          const SecurityPolicy(),
          (a) => a.get('/x', (c) => c.text('ok')),
        );
        expect((await TestClient(app, Env()).get('/x')).status, 200);
      },
    );

    test(
      'a declared route rejects a missing token and admits a valid one',
      () async {
        final app = build(
          SecurityPolicy(verifiers: verifiers),
          (a) => a.get(
            '/x',
            (c) => c.text('ok'),
            doc: const RouteDoc(success: Success(), security: [bearer]),
          ),
        );
        expect((await TestClient(app, Env()).get('/x')).status, 401);
        expect(
          (await TestClient(
            app,
            Env(),
          ).get('/x', headers: {'authorization': 'Bearer ok'})).status,
          200,
        );
      },
    );

    test(
      'an explicitly public route ([]) overrides a non-empty default',
      () async {
        final app = build(
          SecurityPolicy(defaults: const [bearer], verifiers: verifiers),
          (a) => a.get(
            '/x',
            (c) => c.text('ok'),
            doc: const RouteDoc(success: Success(), security: []),
          ),
        );
        expect((await TestClient(app, Env()).get('/x')).status, 200);
      },
    );

    test(
      'with a non-empty default an unmatched path is 401, not 404 '
      '(secure-by-default auth wall); an authenticated one reveals the 404',
      () async {
        final app = build(
          SecurityPolicy(defaults: const [bearer], verifiers: verifiers),
          (a) => a.get('/x', (c) => c.text('ok')),
        );
        expect((await TestClient(app, Env()).get('/nope')).status, 401);
        expect(
          (await TestClient(
            app,
            Env(),
          ).get('/nope', headers: {'authorization': 'Bearer ok'})).status,
          404,
        );
      },
    );

    test(
      'an async verifier is awaited before admitting or rejecting',
      () async {
        // The plain `verifiers` map above never returns a Future — `_admit`'s
        // synchronous branch is what every other test in this file exercises.
        // A verifier that genuinely returns `Future<bool>` (an async token
        // introspection call, say) drives the other branch: `result.then(...)`.
        final app = build(
          SecurityPolicy(
            verifiers: {
              'bearer': (Context<Env> c) async =>
                  c.header('authorization') == 'Bearer ok',
            },
          ),
          (a) => a.get(
            '/x',
            (c) => c.text('ok'),
            doc: const RouteDoc(success: Success(), security: [bearer]),
          ),
        );
        expect((await TestClient(app, Env()).get('/x')).status, 401);
        expect(
          (await TestClient(
            app,
            Env(),
          ).get('/x', headers: {'authorization': 'Bearer ok'})).status,
          200,
        );
      },
    );

    test('multiple declared schemes are OR-combined: any one admitting is '
        'enough', () async {
      final app = build(
        SecurityPolicy(
          verifiers: {
            'apiKey': (Context<Env> c) => false, // never admits
            'bearer': (Context<Env> c) =>
                c.header('authorization') == 'Bearer ok',
          },
        ),
        (a) => a.get(
          '/x',
          (c) => c.text('ok'),
          doc: const RouteDoc(success: Success(), security: [apiKey, bearer]),
        ),
      );
      // apiKey's verifier always refuses; bearer's admits with the right
      // header — one passing scheme is enough even though the first fails.
      expect(
        (await TestClient(
          app,
          Env(),
        ).get('/x', headers: {'authorization': 'Bearer ok'})).status,
        200,
      );
      // Neither passes: apiKey always refuses, bearer sees no token.
      expect((await TestClient(app, Env()).get('/x')).status, 401);
    });

    test('a declared scheme with no registered verifier is skipped, not '
        'treated as an automatic pass', () async {
      // `security: [apiKey, bearer]` but `policy.verifiers` (the `verifiers`
      // map above) has no entry for 'apiKey' at all — not one that returns
      // false, one that is simply absent. `_admit` must fall through to the
      // next scheme rather than either admitting by default or getting stuck.
      final app = build(
        SecurityPolicy(verifiers: verifiers),
        (a) => a.get(
          '/x',
          (c) => c.text('ok'),
          doc: const RouteDoc(success: Success(), security: [apiKey, bearer]),
        ),
      );
      expect((await TestClient(app, Env()).get('/x')).status, 401);
      expect(
        (await TestClient(
          app,
          Env(),
        ).get('/x', headers: {'authorization': 'Bearer ok'})).status,
        200,
      );
    });
  });
}
