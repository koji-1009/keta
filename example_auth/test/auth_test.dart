import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_auth_example/app.dart';
import 'package:keta_auth_example/env.dart';
import 'package:test/test.dart';

TestClient<Env> newClient() =>
    TestClient(buildApp(), Env(StdoutLog(flushInterval: Duration.zero)));

void main() {
  test('a public route needs no token', () async {
    expect((await newClient().get('/public')).text(), 'anyone can read this');
  });

  test('the guarded route enforces auth (401) and role (403)', () async {
    final client = newClient();

    // No token → 401.
    expect((await client.get('/admin/whoami')).status, 401);
    // Valid token, wrong role → 403.
    expect(
      (await client.get(
        '/admin/whoami',
        headers: {'authorization': 'Bearer member-token'},
      )).status,
      403,
    );
    // Valid admin token → 200 with the resolved role.
    final ok = await client.get(
      '/admin/whoami',
      headers: {'authorization': 'Bearer admin-token'},
    );
    expect(ok.status, 200);
    expect(ok.json(), {'role': 'admin'});
  });
}
