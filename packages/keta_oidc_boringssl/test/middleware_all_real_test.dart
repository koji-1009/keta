/// The all-real integration path for oidc(): [BoringSslVerifier] + StaticJwks
/// + a keta_native-signed token, driven through a real app composition with
/// TestClient. keta_oidc's own middleware suite covers every branch over a
/// stub verifier; this test lives HERE, beside the real implementation,
/// because placing it there would make keta_oidc dev-depend on this package —
/// a cycle, since this package depends on keta_oidc.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_native/testing.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_oidc_boringssl/keta_oidc_boringssl.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';

Response _meHandler(Context<Object?> c) {
  final p = c.get(oidcPrincipal);
  return Response.json({'sub': p.subject, 'scopes': p.scopes.toList()..sort()});
}

void main() {
  test(
    'all-real path: BoringSslVerifier + StaticJwks + a signed token → 200',
    () async {
      final pair = RsaKeyPair.generate();
      final token = signedToken(
        alg: 'RS256',
        kid: 'k1',
        sign: pair.signPkcs1Sha256,
      );
      final source = StaticJwks.parse(
        jwksJson([rsaJwkOf(pair, kid: 'k1', alg: 'RS256')]),
      );
      final validator = JwtValidator(
        verifier: BoringSslVerifier(),
        algorithms: {JwsAlgorithm.rs256},
        issuer: 'https://issuer',
        audience: 'api://resource',
      );
      final app = App<Object?>()
        ..use(oidc(jwks: source, validator: validator))
        ..get('/me', _meHandler);
      final res = await TestClient<Object?>(
        app,
        null,
      ).get('/me', headers: _auth(token));
      expect(res.status, 200);
      expect(res.json(), {'sub': 'user-1', 'scopes': <String>[]});
    },
  );
}

Map<String, String> _auth(String token) => {'authorization': 'Bearer $token'};
