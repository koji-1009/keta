/// Drives every route through TestClient with no sockets and no live IdP: a
/// freshly generated RSA key pair (`package:keta_native/testing.dart`) stands
/// in for the identity provider, `StaticJwks` stands in for its JWKS endpoint,
/// and `BoringSslVerifier` does the exact same signature check
/// bin/main.dart's production wiring (`HttpJwksSource.discover`) uses — only
/// the key *source* differs between this suite and a real deployment.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_native/testing.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_oidc_example/app.dart';
import 'package:keta_oidc_example/env.dart';
import 'package:test/test.dart';

const _issuer = 'https://issuer.example.test/';
const _audience = 'api://oidc-example';

/// Encodes [bytes] as unpadded base64url — the JOSE segment encoding.
String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Encodes a JSON [value] as an unpadded base64url segment.
String _b64uJson(Object? value) => _b64u(utf8.encode(jsonEncode(value)));

/// A JWKS entry (decoded JSON) for an RSA [pair]. keta_oidc's own signing/JWKS
/// test helpers are internal to that package (not part of its public surface —
/// signing is the IdP's job, not a resource server's), so this is hand-rolled
/// the same way any app integrating keta_oidc would have to build its own test
/// fixtures.
Map<String, Object?> _rsaJwk(RsaKeyPair pair, {required String kid}) => {
  'kty': 'RSA',
  'kid': kid,
  'alg': 'RS256',
  'n': _b64u(pair.modulus),
  'e': _b64u(pair.exponent),
};

/// Signs a compact JWS with [pair] over the real `"<header>.<payload>"`
/// signing input, so every test token verifies under real BoringSSL crypto —
/// the same backend bin/main.dart wires in production. [claims] override the
/// defaults (a token valid for an hour, for `_issuer`/`_audience`).
String _token(
  RsaKeyPair pair, {
  String kid = 'k1',
  Map<String, Object?> claims = const {},
}) {
  final header = _b64uJson({'alg': 'RS256', 'kid': kid});
  final payload = _b64uJson({
    'iss': _issuer,
    'aud': _audience,
    'sub': 'user-1',
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
    ...claims,
  });
  final signingInput = Uint8List.fromList(ascii.encode('$header.$payload'));
  final signature = pair.signPkcs1Sha256(signingInput);
  return '$header.$payload.${_b64u(signature)}';
}

/// Builds the app + [Env] over one freshly generated RSA key pair — the
/// test-time stand-in for an identity provider's JWKS endpoint (`StaticJwks`)
/// plus the real verifier (`BoringSslVerifier`), matching bin/main.dart's
/// wiring exactly except for where the keys come from. Returns the pair too,
/// so a test can sign tokens against the exact key `jwks` holds.
(App<Env> app, Env env, RsaKeyPair pair) _harness() {
  final pair = RsaKeyPair.generate();
  final jwks = StaticJwks.parse(
    jsonEncode({
      'keys': [_rsaJwk(pair, kid: 'k1')],
    }),
  );
  final validator = JwtValidator(
    verifier: BoringSslVerifier(),
    algorithms: {JwsAlgorithm.rs256},
    issuer: _issuer,
    audience: _audience,
  );
  final app = buildApp(jwks: jwks, validator: validator);
  final env = Env(StdoutLog(flushInterval: Duration.zero), jwks, validator);
  return (app, env, pair);
}

void main() {
  test('the public route needs no token', () async {
    final (app, env, _) = _harness();
    final res = await TestClient(app, env).get('/public');
    expect(res.status, 200);
    expect(res.json(), {'message': 'no token needed'});
  });

  group('/api/me', () {
    test('no token: 401 with the bare Bearer challenge', () async {
      final (app, env, _) = _harness();
      final res = await TestClient(app, env).get('/api/me');
      expect(res.status, 401);
      expect(res.headers['www-authenticate'], 'Bearer');
    });

    test('a malformed token: 401 invalid_token', () async {
      final (app, env, _) = _harness();
      final res = await TestClient(
        app,
        env,
      ).get('/api/me', headers: {'authorization': 'Bearer garbage'});
      expect(res.status, 401);
      expect(
        res.headers['www-authenticate'],
        contains('error="invalid_token"'),
      );
    });

    test(
      'a valid token: 200 with sub, scopes, and the "org" custom claim',
      () async {
        final (app, env, pair) = _harness();
        final token = _token(
          pair,
          claims: {'scope': 'read write', 'org': 'acme'},
        );
        final res = await TestClient(
          app,
          env,
        ).get('/api/me', headers: {'authorization': 'Bearer $token'});
        expect(res.status, 200);
        expect(res.json(), {
          'sub': 'user-1',
          'scopes': ['read', 'write'],
          'org': 'acme',
        });
      },
    );
  });

  group('/api/reports (requireScopes)', () {
    test('a token without "reports:read": 403 insufficient_scope', () async {
      final (app, env, pair) = _harness();
      final token = _token(pair, claims: {'scope': 'read'});
      final res = await TestClient(
        app,
        env,
      ).get('/api/reports', headers: {'authorization': 'Bearer $token'});
      expect(res.status, 403);
      expect(
        res.headers['www-authenticate'],
        contains('error="insufficient_scope"'),
      );
    });

    test('a token with "reports:read": 200 with the report list', () async {
      final (app, env, pair) = _harness();
      final token = _token(pair, claims: {'scope': 'reports:read'});
      final res = await TestClient(
        app,
        env,
      ).get('/api/reports', headers: {'authorization': 'Bearer $token'});
      expect(res.status, 200);
      expect(res.json(), {
        'reports': ['2026-q1-summary', '2026-q2-summary'],
      });
    });
  });

  group('/api/me/events (SSE, auth-before-stream)', () {
    test('no token: 401 before any stream opens', () async {
      final (app, env, _) = _harness();
      final res = await TestClient(app, env).get('/api/me/events');
      expect(res.status, 401);
      expect(res.headers['www-authenticate'], 'Bearer');
    });

    test('a valid token: 200 with an SSE content-type', () async {
      final (app, env, pair) = _harness();
      final token = _token(pair);
      final router = app.compile(env);
      final response = await router.dispatch(
        _Req(
          'GET',
          '/api/me/events',
          headers: {'authorization': 'Bearer $token'},
        ),
      );
      expect(response.status, 200);
      expect(response.headers['content-type'], [
        'text/event-stream; charset=utf-8',
      ]);
      // Never drained via TestClient — an open SSE body hangs it forever, and
      // proving the gate's status/headers is the whole point of this route
      // (../auth/test/revocation_test.dart is where an SSE body is actually
      // read to completion, for a different demonstration).
      await (response.body as Stream<List<int>>).listen((_) {}).cancel();
    });
  });
}

/// A minimal [TransportRequest] so a test can reach the SSE route's raw
/// streaming [Response] directly — the same shape
/// ../auth/test/revocation_test.dart uses, since `TestClient` has no dedicated
/// SSE helper and would hang forever draining an open one.
class _Req implements TransportRequest {
  _Req(this.method, String path, {Map<String, String> headers = const {}})
    : uri = Uri.parse(path),
      headers = {
        for (final e in headers.entries) e.key.toLowerCase(): [e.value],
      };
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, List<String>> headers;
  @override
  Stream<List<int>> get bodyStream => const Stream.empty();
  @override
  String get remoteAddress => 'test';
  @override
  Future<void> get closed => Completer<void>().future;
}
