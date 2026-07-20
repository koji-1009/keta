import 'dart:convert';
import 'dart:typed_data';

import 'package:keta/keta.dart';
import 'package:keta_native/testing.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_oidc_boringssl/keta_oidc_boringssl.dart';

import 'app.dart';
import 'env.dart';

/// The issuer the demo mints and validates tokens for. A `.invalid` host
/// (RFC 6761) makes it unmistakable that nothing here reaches a real network.
const demoIssuer = 'https://demo.keta.invalid/';

/// The audience the demo mints and validates tokens for.
const demoAudience = 'api://keta-oidc-demo';

const _demoKid = 'demo-key';

/// Everything [runnable, offline] the demo needs: the wired [app], the [env]
/// that carries it, and one ready-to-use bearer [token] that verifies against
/// it.
typedef Demo = ({App<Env> app, Env env, String token});

/// Builds the resource server wired to verify against an **in-process** key,
/// and mints one valid token for it — so the example runs with no identity
/// provider and no network.
///
/// This function plays **both** sides of OIDC, which a real deployment never
/// does. In production the identity provider holds the signing key and mints
/// tokens; this server only ever *verifies* (that is the whole point of a
/// resource server, and why keta_native exposes no signing in its production
/// surface). Here, `package:keta_native/testing.dart` — the key-generation
/// support meant for building fixtures — stands in for the IdP: it generates an
/// RSA key, this function publishes the public half as a [StaticJwks], and
/// mints a single token. The signature check that then runs is the *exact*
/// [BoringSslVerifier] path `bin/main.dart` uses in production; only the key
/// source differs. It is factored out of `bin/demo.dart` so a test can assert
/// the minted token actually verifies end to end.
Demo buildDemo() {
  final pair = RsaKeyPair.generate();
  final jwks = StaticJwks.parse(
    jsonEncode({
      'keys': [
        {
          'kty': 'RSA',
          'kid': _demoKid,
          'alg': 'RS256',
          'n': _b64u(pair.modulus),
          'e': _b64u(pair.exponent),
        },
      ],
    }),
  );
  final validator = JwtValidator(
    verifier: BoringSslVerifier(),
    algorithms: {JwsAlgorithm.rs256},
    issuer: demoIssuer,
    audience: demoAudience,
  );
  final app = buildApp(jwks: jwks, validator: validator);
  final env = Env(StdoutLog(), jwks, validator);
  return (app: app, env: env, token: _mintToken(pair));
}

/// Mints a compact JWS the demo's [StaticJwks]/[JwtValidator] accept: RS256,
/// valid for an hour, carrying the `reports:read` scope (so it clears
/// `requireScopes`) and an `org` custom claim. Signs over the real
/// `"<header>.<payload>"` input, so it verifies under real crypto.
String _mintToken(RsaKeyPair pair) {
  final header = _b64u(
    utf8.encode(jsonEncode({'alg': 'RS256', 'kid': _demoKid})),
  );
  final payload = _b64u(
    utf8.encode(
      jsonEncode({
        'iss': demoIssuer,
        'aud': demoAudience,
        'sub': 'demo-user',
        'scope': 'reports:read',
        'org': 'keta-demo',
        'exp':
            DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000,
      }),
    ),
  );
  final signingInput = Uint8List.fromList(ascii.encode('$header.$payload'));
  return '$header.$payload.${_b64u(pair.signPkcs1Sha256(signingInput))}';
}

/// Unpadded base64url — the JOSE segment encoding.
String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
