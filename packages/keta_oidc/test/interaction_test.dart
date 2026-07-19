/// Cross-cutting interaction review for keta_oidc: how oidc()/requireScopes()
/// and the native verifier compose with the REST of the framework — timeout(),
/// rateLimit(), the SSE/abort lifecycle, and the isolate boundary. These pin
/// invariants the package docs claim (or imply) about *composition*, not the
/// internals of any one unit (those live in middleware_test / http_jwks_source
/// / boringssl_verifier tests).
library;

import 'dart:async';
import 'dart:isolate';

import 'package:keta/keta.dart';
import 'package:keta_native/testing.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

final _fixedNow = DateTime.utc(2026, 7, 19, 12);

JwtValidator _stubValidator({bool signatureOk = true}) => JwtValidator(
  verifier: StubVerifier(result: signatureOk),
  algorithms: {JwsAlgorithm.rs256},
  issuer: 'https://issuer',
  audience: 'api://resource',
  now: () => _fixedNow,
);

JwksSource _stubJwks() =>
    StaticJwks.parse(jwksJson([rsaJwkJson(kid: 'k1', alg: 'RS256')]));

String _token({String kid = 'k1', Map<String, Object?> claims = const {}}) =>
    compactJws(
      header: {'alg': 'RS256', 'kid': kid},
      payload: {
        'iss': 'https://issuer',
        'aud': 'api://resource',
        'sub': 'user-1',
        'exp': epochSeconds(_fixedNow.add(const Duration(hours: 1))),
        ...claims,
      },
    );

Map<String, String> _auth(String token) => {'authorization': 'Bearer $token'};

/// A JwksSource whose resolve never completes — the "cold source / slow IdP
/// that hangs" case concern (1) is about.
class _HangingJwks implements JwksSource {
  @override
  Future<Jwk> resolve(JoseHeader header) => Completer<Jwk>().future;
}

/// A JwksSource that records every resolve, so a test can prove oidc() never
/// ran when an earlier gate refused the request.
class _RecordingJwks implements JwksSource {
  _RecordingJwks(this._delegate);
  final JwksSource _delegate;
  int resolveCalls = 0;
  @override
  Future<Jwk> resolve(JoseHeader header) {
    resolveCalls++;
    return _delegate.resolve(header);
  }
}

/// A [TransportRequest] with a caller-controlled `closed` signal and no body —
/// the same shape examples/oidc uses to reach a raw streaming Response, plus a
/// way to fire the client-disconnect / going-away seam on demand.
class _Req implements TransportRequest {
  _Req(
    this.method,
    String path, {
    Map<String, String> headers = const {},
    Future<void>? closed,
  }) : uri = Uri.parse(path),
       headers = {
         for (final e in headers.entries) e.key.toLowerCase(): [e.value],
       },
       closed = closed ?? Completer<void>().future;
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
  final Future<void> closed;
}

void main() {
  group('concern 1 — oidc() layered under timeout()', () {
    test('a hung JWKS resolve is bounded by timeout() and answers a clean 504, '
        'not a leaked pending future', () async {
      final app = App<Object?>()
        ..use(timeout(const Duration(milliseconds: 50)))
        ..use(oidc(jwks: _HangingJwks(), validator: _stubValidator()))
        ..get('/me', (c) => Response(200));
      final router = app.compile(null);
      final res = await router.dispatch(
        _Req('GET', '/me', headers: _auth(_token())),
      );
      // timeout() armed because oidc() is async (returns a Future<Response>),
      // so the hung resolve is cut at the deadline and mapped to 504 by the
      // router's last-resort fallback (GatewayTimeout is a KetaException).
      expect(res.status, 504);
    });

    test(
      'the SSE-under-oidc case: timeout() bounds time-to-response through auth '
      '(a hung resolve 504s before any stream opens)',
      () async {
        final app = App<Object?>()
          ..use(timeout(const Duration(milliseconds: 50)))
          ..use(oidc(jwks: _HangingJwks(), validator: _stubValidator()))
          ..get('/events', (c) => c.sse(const Stream.empty()));
        final router = app.compile(null);
        final res = await router.dispatch(
          _Req('GET', '/events', headers: _auth(_token())),
        );
        expect(res.status, 504);
      },
    );

    test(
      'once auth+handler produce the SSE Response, timeout() releases and the '
      'stream is NOT cut at the deadline',
      () async {
        // A short timeout, a fast (cached) resolve, and a long-lived SSE stream.
        // The timer must be cancelled when the Response is produced, so the
        // stream keeps flowing well past the timeout window.
        final ticks = StreamController<SseEvent>();
        final app = App<Object?>()
          ..use(timeout(const Duration(milliseconds: 30)))
          ..use(oidc(jwks: _stubJwks(), validator: _stubValidator()))
          ..get('/events', (c) => c.sse(ticks.stream));
        final router = app.compile(null);
        final res = await router.dispatch(
          _Req('GET', '/events', headers: _auth(_token())),
        );
        expect(res.status, 200);
        expect(res.headers['content-type'], [
          'text/event-stream; charset=utf-8',
        ]);

        final seen = <String>[];
        final sub = (res.body as Stream<List<int>>).listen(
          (b) => seen.add(String.fromCharCodes(b)),
        );
        // Well past the 30ms timeout: if timeout() had cut the stream, no event
        // added now would ever arrive.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        ticks.add(SseEvent('after-timeout-window'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(seen.join(), contains('after-timeout-window'));
        await ticks.close();
        await sub.cancel();
      },
    );
  });

  group('concern 2 — oidc() with rateLimit()/admission', () {
    test('a per-IP rateLimit() BEFORE oidc() refuses a flood with 429 WITHOUT '
        'oidc() (no JWKS resolve) ever running', () async {
      final jwks = _RecordingJwks(_stubJwks());
      final app = App<Object?>()
        ..use(
          rateLimit(
            key: (c) => c.remoteAddress,
            capacity: 1,
            refillPeriod: const Duration(minutes: 1),
          ),
        )
        ..use(oidc(jwks: jwks, validator: _stubValidator()))
        ..get('/me', (c) => Response(200));
      final router = app.compile(null);

      final first = await router.dispatch(
        _Req('GET', '/me', headers: _auth(_token())),
      );
      expect(first.status, 200);
      expect(jwks.resolveCalls, 1, reason: 'the admitted request authed');

      final refused = await router.dispatch(
        _Req('GET', '/me', headers: _auth(_token())),
      );
      expect(refused.status, 429);
      expect(refused.headers['retry-after'], isNotNull);
      // The whole point: the refused flood spent NO authentication work.
      expect(
        jwks.resolveCalls,
        1,
        reason: 'rateLimit() short-circuited before oidc() ran',
      );
    });

    test(
      'an unknown-kid spray through oidc() over HttpJwksSource is cooled down: '
      'many garbage kids trigger ONE miss-refresh, never a fetch-per-request '
      'hammer on the IdP',
      () async {
        var fetches = 0;
        final jwksBody = jwksJson([rsaJwkJson(kid: 'k1', alg: 'RS256')]);
        final source = HttpJwksSource.fromJwksUri(
          Uri.parse('https://issuer.example/jwks'),
          fetch: (uri) async {
            fetches++;
            return jwksBody;
          },
          now: () => _fixedNow, // frozen: the cooldown never elapses mid-test
        );
        final app = App<Object?>()
          ..use(oidc(jwks: source, validator: _stubValidator()))
          ..get('/me', (c) => Response(200));
        final router = app.compile(null);

        for (var i = 0; i < 25; i++) {
          final res = await router.dispatch(
            _Req('GET', '/me', headers: _auth(_token(kid: 'garbage-$i'))),
          );
          expect(res.status, 401);
          expect(
            res.headers['www-authenticate']!.first,
            contains('error="invalid_token"'),
          );
        }
        // 1 cold load + exactly 1 miss-triggered refresh; every later unknown
        // kid is an immediate miss suppressed by minRefreshInterval. NOT 25+.
        expect(
          fetches,
          2,
          reason: 'single-flight + cooldown bounds IdP fetches under a spray',
        );
      },
    );
  });

  group('concern 3 — shutdown / client-disconnect drains an SSE under oidc()', () {
    test(
      'firing the request\'s going-away seam ends an authenticated SSE stream '
      'cleanly (onDone), tearing down its source subscription',
      () async {
        final going = Completer<void>();
        var sourceCancelled = false;
        // A source that never completes on its own — only an abort can end it.
        final source = StreamController<SseEvent>(
          onCancel: () => sourceCancelled = true,
        );
        final app = App<Object?>()
          ..use(oidc(jwks: _stubJwks(), validator: _stubValidator()))
          ..get('/events', (c) => c.sse(source.stream));
        final router = app.compile(null);
        final res = await router.dispatch(
          _Req(
            'GET',
            '/events',
            headers: _auth(_token()),
            closed: going.future,
          ),
        );
        expect(res.status, 200);

        var done = false;
        final sub = (res.body as Stream<List<int>>).listen(
          (_) {},
          onDone: () => done = true,
        );
        // Simulate graceful shutdown / client disconnect: dispatch wired
        // request.closed → ctx.abort(), which the SSE body observes and ends on.
        going.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(done, isTrue, reason: 'the stream wound down on abort');
        expect(sourceCancelled, isTrue, reason: 'the source sub was cancelled');
        await sub.cancel();
        await source.close();
      },
    );
  });

  group('concern 5 — contract consistency across packages', () {
    test(
      'oidc()\'s raw 503 Response is seen with its true status by an outer '
      'response-observing middleware (accessLog-shaped), not double-handled',
      () async {
        final observed = <int>[];
        Middleware<Object?> statusTap() =>
            (c, next) => chain(next(c), (Response r) {
              observed.add(r.status);
              return r;
            });
        final app = App<Object?>()
          ..use(statusTap())
          ..use(
            oidc(
              jwks: const _ThrowingJwks(JwksUnavailable('down')),
              validator: _stubValidator(),
            ),
          )
          ..get('/me', (c) => Response(200));
        final router = app.compile(null);
        final res = await router.dispatch(
          _Req('GET', '/me', headers: _auth(_token())),
        );
        expect(res.status, 503);
        // The outer middleware saw the 503 as a returned Response (once), which
        // is how accessLog()/otel() count it — never as a thrown exception.
        expect(observed, [503]);
      },
    );

    test('oidcPrincipal Key coexists with an unrelated Context key', () async {
      final other = Key<String>('app.tenant');
      final app = App<Object?>()
        ..use((c, next) {
          c.set(other, 'acme');
          return next(c);
        })
        ..use(oidc(jwks: _stubJwks(), validator: _stubValidator()))
        ..get('/me', (c) {
          final p = c.get(oidcPrincipal);
          return Response.json({'sub': p.subject, 'tenant': c.get(other)});
        });
      final router = app.compile(null);
      final res = await router.dispatch(
        _Req('GET', '/me', headers: _auth(_token())),
      );
      expect(res.status, 200);
    });
  });

  group('concern 6 — native layer / isolate boundary', () {
    test('a native EVP_PKEY-backed key is UNSENDABLE across isolates, so '
        'serve(isolates>1) can never silently share one EVP_PKEY / NativeFinalizer '
        'between isolates — it fails fast instead', () async {
      final pub = RsaKeyPair.generate().publicKey();
      Object? caught;
      try {
        // Sending the native key across the boundary is what serve()'s
        // Isolate.spawn(boot, ...) would attempt for a boot capturing it.
        await Isolate.spawn(_unreachableEntry, pub);
      } catch (e) {
        caught = e;
      }
      expect(
        caught,
        isA<ArgumentError>(),
        reason: 'native key material cannot cross an isolate boundary',
      );
      expect(
        '$caught',
        contains('unsendable'),
        reason: 'this is the ArgumentError serve() maps to a StateError',
      );
    });
  });
}

/// A top-level isolate entry that is never actually reached: the native key
/// sent as its message is rejected as unsendable before the isolate spawns.
void _unreachableEntry(Object message) {}

/// A JwksSource that always throws — for the non-token failure path in the
/// contract-consistency group.
class _ThrowingJwks implements JwksSource {
  const _ThrowingJwks(this.error);
  final Exception error;
  @override
  Future<Jwk> resolve(JoseHeader header) async => throw error;
}
