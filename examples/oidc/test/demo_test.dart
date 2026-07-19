/// The self-contained demo (`bin/demo.dart` via `lib/demo.dart`) claims one
/// load-bearing invariant: the token it prints actually verifies against the
/// server it starts, through the real BoringSSL path. This pins that — and that
/// the minted token clears `requireScopes` — so the "just run it and curl"
/// story in the README can never silently rot.
library;

import 'package:keta/test.dart';
import 'package:keta_oidc_example/demo.dart';
import 'package:test/test.dart';

void main() {
  test('the demo token verifies against /api/me with its claims', () async {
    final demo = buildDemo();
    final res = await TestClient(
      demo.app,
      demo.env,
    ).get('/api/me', headers: {'authorization': 'Bearer ${demo.token}'});
    expect(res.status, 200);
    expect(res.json(), {
      'sub': 'demo-user',
      'scopes': ['reports:read'],
      'org': 'keta-demo',
    });
  });

  test('the demo token carries the scope /api/reports requires', () async {
    final demo = buildDemo();
    final res = await TestClient(
      demo.app,
      demo.env,
    ).get('/api/reports', headers: {'authorization': 'Bearer ${demo.token}'});
    expect(res.status, 200);
    expect((res.json()! as Map)['reports'], isNotEmpty);
  });

  test('the demo still refuses an unauthenticated request', () async {
    final demo = buildDemo();
    final res = await TestClient(demo.app, demo.env).get('/api/me');
    expect(res.status, 401);
    expect(res.headers['www-authenticate'], 'Bearer');
  });
}
