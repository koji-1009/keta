import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_oidc_boringssl/keta_oidc_boringssl.dart';
import 'package:keta_oidc_example/app.dart';
import 'package:keta_oidc_example/env.dart';

/// Configuration from the environment only (keta's §9 posture: no config files
/// read at runtime): the identity provider's issuer, and the audience/API
/// identifier it mints tokens for this API.
Future<void> main() async {
  final issuer = Platform.environment['KETA_OIDC_ISSUER'];
  final audience = Platform.environment['KETA_OIDC_AUDIENCE'];
  if (issuer == null || audience == null) {
    // Fail loudly, before anything is bound to a port, naming exactly what is
    // missing — the opposite of a 500 on the first request that needed it.
    stderr.writeln(
      'keta_oidc_example requires KETA_OIDC_ISSUER and KETA_OIDC_AUDIENCE to '
      'be set — your identity provider\'s issuer URL and the audience (API '
      'identifier) it mints tokens for. Example:\n\n'
      '  KETA_OIDC_ISSUER=https://your-tenant.example.com/ \\\n'
      '  KETA_OIDC_AUDIENCE=api://your-api \\\n'
      '  dart run bin/main.dart\n',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  // HttpJwksSource.discover finds jwks_uri via OIDC Discovery
  // (<issuer>/.well-known/openid-configuration) and checks that the discovery
  // document's own "issuer" equals the one configured here (RFC 8414 §3.3) —
  // a mismatch is a JwksDiscoveryException, which oidc() turns into a 500, not
  // a 401 (it is a trust failure, not the caller's fault).
  final jwks = HttpJwksSource.discover(issuer: issuer);

  // RS256 is the algorithm the overwhelming majority of IdPs sign with. The
  // allowlist is deliberately narrow, not "every supported algorithm" — widen
  // it only to what your IdP actually issues (see JwtValidator's doc on why
  // the tightest correct set is per-deployment).
  final validator = JwtValidator(
    verifier: BoringSslVerifier(),
    algorithms: {JwsAlgorithm.rs256},
    issuer: issuer,
    audience: audience,
  );

  final server = await buildApp(
    jwks: jwks,
    validator: validator,
  ).serve(() async => Env(StdoutLog(), jwks, validator), port: 8080);
  stdout.writeln(
    'keta_oidc_example listening on :8080 (issuer: $issuer, audience: $audience)',
  );
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
