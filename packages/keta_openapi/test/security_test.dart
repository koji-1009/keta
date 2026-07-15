import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_openapi/keta_openapi.dart';
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
            doc: const RouteDoc(security: [bearer]),
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
            doc: const RouteDoc(security: []),
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
  });
}
