import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_auth_example/app.dart';
import 'package:keta_auth_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

TestClient<Env> newClient() =>
    TestClient(buildApp(), Env(StdoutLog(flushInterval: Duration.zero)));

void main() {
  group('runtime gate (enforceSecurity)', () {
    test('a public route needs no token', () async {
      expect((await newClient().get('/public')).text(), 'anyone can read this');
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
  });

  test('the same declaration drives the OpenAPI output', () {
    final doc = OpenApi.fromRoutes(buildApp().routes).toJson();
    final op =
        ((doc['paths'] as Map)['/admin/whoami'] as Map)['get']
            as Map<String, Object?>;
    expect(op['security'], [
      {'bearer': <String>[]},
    ]);
    expect((op['responses'] as Map).containsKey('401'), isTrue);
    expect(((doc['components'] as Map)['securitySchemes'] as Map)['bearer'], {
      'type': 'http',
      'scheme': 'bearer',
    });
    // /public declares no security → no security key, no auto-401.
    final pub =
        ((doc['paths'] as Map)['/public'] as Map)['get'] as Map<String, Object?>;
    expect(pub.containsKey('security'), isFalse);
  });
}
