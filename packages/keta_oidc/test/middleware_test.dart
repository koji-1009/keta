/// Drives oidc() and requireScopes() through a real app composition with
/// TestClient: the two 401 shapes, every JwtRejection → invalid_token, the
/// 503/500 non-token failures, scope authorization and scope-claim union,
/// principal injection and non-leakage, the author-defect StateError, an
/// upgrade route gated by auth, and one all-real path (BoringSslVerifier +
/// StaticJwks + a keta_native-signed token).
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_native/testing.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_oidc_boringssl/keta_oidc_boringssl.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';
import 'support.dart';

/// A fixed clock so token expiry is deterministic on the stub path.
final _fixedNow = DateTime.utc(2026, 7, 19, 12);

/// A JwksSource that always throws — for the non-token failure paths.
class _ThrowingJwks implements JwksSource {
  _ThrowingJwks(this.error);
  final Exception error;
  @override
  Future<Jwk> resolve(JoseHeader header) async => throw error;
}

/// A [Log] that records emitted lines in memory, so a test can assert exactly
/// what the middleware wrote (mirrors keta's own test MemLog). `withFields`
/// keeps recording into the same store, as a real per-request logger does.
class _MemLog implements Log {
  _MemLog(this.lines, [this._baked = const {}]);
  final List<Map<String, Object?>> lines;
  final Map<String, Object?> _baked;

  void _add(String level, String msg, Map<String, Object?> fields) =>
      lines.add({'level': level, 'msg': msg, ..._baked, ...fields});

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('debug', msg, fields);
  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('info', msg, fields);
  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('warn', msg, fields);
  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) => _add('error', msg, {...fields, if (error != null) 'error': '$error'});
  @override
  Future<void> flush() async {}
  @override
  Log withFields(Map<String, Object?> fields) =>
      _MemLog(lines, {..._baked, ...fields});
}

/// A minimal env carrying an inspectable [_MemLog].
class _LogEnv implements HasLog {
  _LogEnv(this.log);
  @override
  final Log log;
}

Response _meHandler(Context<Object?> c) {
  final p = c.get(oidcPrincipal);
  return Response.json({'sub': p.subject, 'scopes': p.scopes.toList()..sort()});
}

/// A validator over the stub verifier (no real crypto): signature result is
/// [signatureOk], everything else is the standard issuer/audience/allowlist.
JwtValidator _stubValidator({
  bool signatureOk = true,
  Set<JwsAlgorithm>? algorithms,
}) => JwtValidator(
  verifier: StubVerifier(result: signatureOk),
  algorithms: algorithms ?? {JwsAlgorithm.rs256},
  issuer: 'https://issuer',
  audience: 'api://resource',
  now: () => _fixedNow,
);

/// The default single-key JWKS (kid `k1`, RS256) — its components are never
/// imported because the stub verifier ignores them.
JwksSource _stubJwks() =>
    StaticJwks.parse(jwksJson([rsaJwkJson(kid: 'k1', alg: 'RS256')]));

/// Builds an app: oidc() app-wide, a public-once-authed `/me`, and an
/// `/admin/panel` behind `requireScopes(['read','write'])`.
TestClient<Object?> _client({
  required JwtValidator validator,
  JwksSource? jwks,
}) {
  final app = App<Object?>()
    ..use(oidc(jwks: jwks ?? _stubJwks(), validator: validator))
    ..get('/me', _meHandler);
  app.group('/admin')
    ..use(requireScopes(['read', 'write']))
    ..get('/panel', _meHandler);
  return TestClient<Object?>(app, null);
}

/// A stub-path token: valid claims by default, [claims] overriding.
String _token({
  String alg = 'RS256',
  String kid = 'k1',
  Map<String, Object?> claims = const {},
}) => compactJws(
  header: {'alg': alg, 'kid': kid},
  payload: {
    'iss': 'https://issuer',
    'aud': 'api://resource',
    'sub': 'user-1',
    'exp': epochSeconds(_fixedNow.add(const Duration(hours: 1))),
    ...claims,
  },
);

Map<String, String> _auth(String token) => {'authorization': 'Bearer $token'};

void main() {
  group('no Bearer credentials → bare challenge (401, no error code)', () {
    test('a missing Authorization header', () async {
      final res = await _client(validator: _stubValidator()).get('/me');
      expect(res.status, 401);
      expect(res.headers['www-authenticate'], 'Bearer');
    });

    test('a different scheme (Basic) is not Bearer credentials', () async {
      final res = await _client(
        validator: _stubValidator(),
      ).get('/me', headers: {'authorization': 'Basic dXNlcjpwYXNz'});
      expect(res.status, 401);
      expect(res.headers['www-authenticate'], 'Bearer');
    });
  });

  group('bad Bearer credentials → invalid_token (401)', () {
    test('an empty token ("Bearer ")', () async {
      final res = await _client(
        validator: _stubValidator(),
      ).get('/me', headers: {'authorization': 'Bearer '});
      expect(res.status, 401);
      expect(
        res.headers['www-authenticate'],
        contains('error="invalid_token"'),
      );
    });

    test('more than one token ("Bearer a b")', () async {
      final res = await _client(
        validator: _stubValidator(),
      ).get('/me', headers: {'authorization': 'Bearer a b'});
      expect(res.status, 401);
      expect(
        res.headers['www-authenticate'],
        contains('error="invalid_token"'),
      );
    });
  });

  test('a lowercase "bearer" scheme is accepted', () async {
    final res = await _client(
      validator: _stubValidator(),
    ).get('/me', headers: {'authorization': 'bearer ${_token()}'});
    expect(res.status, 200);
    expect(res.json(), {'sub': 'user-1', 'scopes': <String>[]});
  });

  group('each JwtRejection → invalid_token with its category description', () {
    Future<TestResponse> run(
      String token, {
      JwtValidator? validator,
      JwksSource? jwks,
    }) => _client(
      validator: validator ?? _stubValidator(),
      jwks: jwks,
    ).get('/me', headers: _auth(token));

    void expectInvalid(TestResponse res, String description) {
      expect(res.status, 401);
      expect(
        res.headers['www-authenticate'],
        'Bearer error="invalid_token", error_description="$description"',
      );
    }

    test('malformed', () async {
      expectInvalid(await run('garbage-not-a-jwt'), 'the token is malformed');
    });

    test('bad signature', () async {
      final res = await run(
        _token(),
        validator: _stubValidator(signatureOk: false),
      );
      expectInvalid(res, 'the token signature is invalid');
    });

    test('expired', () async {
      final res = await run(
        _token(
          claims: {
            'exp': epochSeconds(_fixedNow.subtract(const Duration(hours: 1))),
          },
        ),
      );
      expectInvalid(res, 'the token is expired');
    });

    test('no expiration', () async {
      // Build a token with no exp: null in the override drops the default exp.
      final noExp = compactJws(
        header: {'alg': 'RS256', 'kid': 'k1'},
        payload: {
          'iss': 'https://issuer',
          'aud': 'api://resource',
          'sub': 'user-1',
        },
      );
      expectInvalid(await run(noExp), 'the token has no expiration');
    });

    test('not yet valid (nbf)', () async {
      final res = await run(
        _token(
          claims: {
            'nbf': epochSeconds(_fixedNow.add(const Duration(hours: 1))),
          },
        ),
      );
      expectInvalid(res, 'the token is not yet valid');
    });

    test('issuer mismatch', () async {
      final res = await run(_token(claims: {'iss': 'https://evil'}));
      expectInvalid(res, 'the token issuer is not accepted');
    });

    test('audience mismatch', () async {
      final res = await run(_token(claims: {'aud': 'api://other'}));
      expectInvalid(res, 'the token audience is not accepted');
    });

    test('algorithm not allowed', () async {
      // Token asks for ES256 while the allowlist is RS256-only.
      final res = await run(_token(alg: 'ES256'));
      expectInvalid(res, 'the token algorithm is not allowed');
    });

    test('unknown key', () async {
      final res = await run(_token(kid: 'not-in-jwks'));
      expectInvalid(res, 'the token key is not recognized');
    });
  });

  group('non-token failures', () {
    test('JwksUnavailable → 503 with no WWW-Authenticate', () async {
      final res = await _client(
        validator: _stubValidator(),
        jwks: _ThrowingJwks(const JwksUnavailable('down')),
      ).get('/me', headers: _auth(_token()));
      expect(res.status, 503);
      expect(res.headers['www-authenticate'], isNull);
    });

    test('JwksDiscoveryException → 500', () async {
      final res = await _client(
        validator: _stubValidator(),
        jwks: _ThrowingJwks(const JwksDiscoveryException('issuer mismatch')),
      ).get('/me', headers: _auth(_token()));
      expect(res.status, 500);
      expect(res.headers['www-authenticate'], isNull);
    });

    test(
      'JwksUnavailable is logged (warn, with cause) before the 503',
      () async {
        final log = _MemLog(<Map<String, Object?>>[]);
        final app = App<_LogEnv>()
          ..use(
            oidc(
              jwks: _ThrowingJwks(
                const JwksUnavailable(
                  'key source unreachable',
                  cause: 'SocketException: connection refused',
                ),
              ),
              validator: _stubValidator(),
            ),
          )
          ..get('/me', (c) => Response(200));
        final res = await TestClient<_LogEnv>(
          app,
          _LogEnv(log),
        ).get('/me', headers: _auth(_token()));

        expect(res.status, 503); // the 503 answer is unchanged
        final warned = log.lines.where((l) => l['level'] == 'warn').toList();
        expect(warned, isNotEmpty);
        expect(warned.first['msg'], 'key source unreachable');
        expect('${warned.first['cause']}', contains('SocketException'));
      },
    );
  });

  group('requireScopes factory-time validation (author defects)', () {
    test('an empty scopes list throws ArgumentError', () {
      expect(() => requireScopes<Object?>([]), throwsA(isA<ArgumentError>()));
    });

    test('a scope with a header-corrupting character throws ArgumentError', () {
      expect(
        () => requireScopes<Object?>(['bad"scope']),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => requireScopes<Object?>(['back\\slash']),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => requireScopes<Object?>(['has space']),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => requireScopes<Object?>(['ok', '']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('valid scope tokens are unaffected', () {
      expect(
        () => requireScopes<Object?>(['read', 'write', 'urn:api:admin']),
        returnsNormally,
      );
    });
  });

  group('principal injection', () {
    test('the handler sees sub, claims, and scopes', () async {
      final res = await _client(
        validator: _stubValidator(),
      ).get('/me', headers: _auth(_token(claims: {'scope': 'read write'})));
      expect(res.status, 200);
      expect(res.json(), {
        'sub': 'user-1',
        'scopes': ['read', 'write'],
      });
    });

    test(
      'a fresh Context per request — no principal leaks across requests',
      () async {
        final client = _client(validator: _stubValidator());
        final authed = await client.get(
          '/me',
          headers: _auth(_token(claims: {'sub': 'alice'})),
        );
        expect((authed.json()! as Map)['sub'], 'alice');

        // A following unauthenticated request must not see alice's principal.
        final anon = await client.get('/me');
        expect(anon.status, 401);

        final bob = await client.get(
          '/me',
          headers: _auth(_token(claims: {'sub': 'bob'})),
        );
        expect((bob.json()! as Map)['sub'], 'bob');
      },
    );
  });

  group('scope-claim union', () {
    Future<Object?> scopesFor(Map<String, Object?> claims) async {
      final res = await _client(
        validator: _stubValidator(),
      ).get('/me', headers: _auth(_token(claims: claims)));
      return (res.json()! as Map)['scopes'];
    }

    test('the RFC 6749 space-delimited "scope" string', () async {
      expect(await scopesFor({'scope': 'a b'}), ['a', 'b']);
    });

    test('the "scp" array variant', () async {
      expect(
        await scopesFor({
          'scp': ['c', 'd'],
        }),
        ['c', 'd'],
      );
    });

    test('both present are unioned', () async {
      expect(
        await scopesFor({
          'scope': 'a',
          'scp': ['b'],
        }),
        ['a', 'b'],
      );
    });
  });

  group('requireScopes', () {
    test('passes when the caller holds every required scope', () async {
      final res = await _client(validator: _stubValidator()).get(
        '/admin/panel',
        headers: _auth(_token(claims: {'scope': 'read write extra'})),
      );
      expect(res.status, 200);
    });

    test(
      'fails 403 with the insufficient_scope challenge when one is missing',
      () async {
        final res = await _client(validator: _stubValidator()).get(
          '/admin/panel',
          headers: _auth(_token(claims: {'scope': 'read'})),
        );
        expect(res.status, 403);
        expect(
          res.headers['www-authenticate'],
          'Bearer error="insufficient_scope", scope="read write"',
        );
      },
    );

    test('without a principal in Context it is a StateError (author defect)', () {
      // Invoked directly (not through oidc): the ordering bug must surface as a
      // thrown StateError, never a 401 that blames the client.
      final middleware = requireScopes<Object?>(['read']);
      final c = testContext<Object?>(null);
      expect(
        () => middleware(c, (_) => Response(200)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('composition with an upgrade route', () {
    TestClient<Object?> upgradeClient() {
      final app = App<Object?>()
        ..use(oidc(jwks: _stubJwks(), validator: _stubValidator()))
        ..get(
          '/ws',
          (c) => Response.upgrade((channel) {
            channel.send('hello');
            channel.close();
          }),
        );
      return TestClient<Object?>(app, null);
    }

    test('an unauthenticated upgrade is refused before the switch', () async {
      final result = await upgradeClient().connect('/ws');
      expect(result.upgraded, isFalse);
      expect(result.rejection!.status, 401);
      expect(result.rejection!.headers['www-authenticate'], 'Bearer');
    });

    test('an authenticated upgrade proceeds', () async {
      final result = await upgradeClient().connect(
        '/ws',
        headers: _auth(_token()),
      );
      expect(result.upgraded, isTrue);
      expect(await result.socket!.messages.first, 'hello');
    });
  });

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
