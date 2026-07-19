/// Pins [HttpJwksSource]: the cache-only happy path with stable identity,
/// single-flight and cooldown on unknown-kid refreshes, lazy TTL refresh,
/// serve-stale on failure, cold-failure JwksUnavailable, rotation, OIDC
/// discovery (issuer verification + jwks_uri extraction), and the timeout wiring
/// of the real-HttpClient default (structurally, without a socket).
library;

import 'dart:async';
import 'dart:io';

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A fetch hook that records every call and delegates to [handler] (given the
/// URL and the zero-based call index).
class Fetcher {
  Fetcher(this.handler);

  final Future<String> Function(Uri url, int index) handler;
  final List<Uri> calls = [];

  int get count => calls.length;

  Future<String> call(Uri url) {
    final index = calls.length;
    calls.add(url);
    return handler(url, index);
  }
}

/// A mutable clock for TTL/cooldown boundaries without real time.
class Clock {
  DateTime t = DateTime.utc(2026, 1, 1);
  DateTime now() => t;
  void advance(Duration d) => t = t.add(d);
}

void main() {
  final jwksUri = Uri.parse('https://issuer.example/jwks');

  group('happy path', () {
    test(
      'resolve is cache-only after the first fetch, identity stable',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        final fetcher = Fetcher((u, i) async => body);
        final source = HttpJwksSource.fromJwksUri(jwksUri, fetch: fetcher.call);

        final a = await source.resolve(headerWith(kid: 'k1'));
        final b = await source.resolve(headerWith(kid: 'k1'));

        expect(identical(a, b), isTrue);
        expect(fetcher.count, 1);
      },
    );

    test(
      'a header with a kid never falls back to a lone mismatched key',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'server-kid')]);
        final fetcher = Fetcher((u, i) async => body);
        final source = HttpJwksSource.fromJwksUri(jwksUri, fetch: fetcher.call);
        await expectLater(
          source.resolve(headerWith(kid: 'other')),
          throwsA(isA<JwtUnknownKey>()),
        );
      },
    );
  });

  group('single-flight', () {
    test(
      'N concurrent unknown-kid resolves share ONE fetch, then all miss',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        final gate = Completer<void>();
        var missFetches = 0;
        final fetcher = Fetcher((u, i) async {
          if (i == 0) return body; // initial load
          missFetches++;
          await gate.future; // hold the single refresh open
          return body; // still lacks the unknown kid
        });
        final source = HttpJwksSource.fromJwksUri(jwksUri, fetch: fetcher.call);

        await source.resolve(headerWith(kid: 'k1')); // prime the cache

        final results = [
          for (var n = 0; n < 5; n++)
            source.resolve(headerWith(kid: 'missing')),
        ];
        // Settle each to its error object so a rejection is not "unhandled".
        final settled = results
            .map((f) => f.then<Object?>((v) => v, onError: (Object e) => e))
            .toList();
        await pumpEventQueue();
        gate.complete();
        final outcomes = await Future.wait(settled);

        expect(missFetches, 1); // exactly one fetch under 5 concurrent misses
        for (final o in outcomes) {
          expect(o, isA<JwtUnknownKey>());
        }
      },
    );
  });

  group('cooldown', () {
    test(
      'a second unknown-kid miss within minRefreshInterval does not fetch',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        final clock = Clock();
        final fetcher = Fetcher((u, i) async => body);
        final source = HttpJwksSource.fromJwksUri(
          jwksUri,
          fetch: fetcher.call,
          minRefreshInterval: const Duration(minutes: 5),
          now: clock.now,
        );

        await source.resolve(headerWith(kid: 'k1')); // cold load: fetch #1
        await expectLater(
          source.resolve(headerWith(kid: 'x')),
          throwsA(isA<JwtUnknownKey>()),
        ); // first miss: fetch #2
        final afterFirstMiss = fetcher.count;
        expect(afterFirstMiss, 2);

        await expectLater(
          source.resolve(headerWith(kid: 'x')),
          throwsA(isA<JwtUnknownKey>()),
        ); // within cooldown: NO fetch
        expect(fetcher.count, afterFirstMiss);

        clock.advance(const Duration(minutes: 6)); // past cooldown
        await expectLater(
          source.resolve(headerWith(kid: 'x')),
          throwsA(isA<JwtUnknownKey>()),
        ); // fetch #3
        expect(fetcher.count, afterFirstMiss + 1);
      },
    );
  });

  group('TTL and staleness', () {
    test('a read past ttl refreshes lazily', () async {
      final clock = Clock();
      final v1 = jwksJson([rsaJwkJson(kid: 'k1')]);
      final v2 = jwksJson([rsaJwkJson(kid: 'k1'), rsaJwkJson(kid: 'k2')]);
      final fetcher = Fetcher((u, i) async => i == 0 ? v1 : v2);
      final source = HttpJwksSource.fromJwksUri(
        jwksUri,
        fetch: fetcher.call,
        ttl: const Duration(minutes: 15),
        minRefreshInterval: const Duration(minutes: 5),
        now: clock.now,
      );

      await source.resolve(headerWith(kid: 'k1')); // fetch #1 -> v1
      expect(fetcher.count, 1);

      clock.advance(const Duration(minutes: 20)); // past ttl and cooldown
      await source.resolve(headerWith(kid: 'k1')); // stale read -> refresh
      expect(fetcher.count, 2);

      final k2 = await source.resolve(headerWith(kid: 'k2')); // now present
      expect(k2.kid, 'k2');
      expect(fetcher.count, 2); // no extra fetch
    });

    test(
      'a refresh failure serves the previously loaded (stale) set',
      () async {
        final clock = Clock();
        final v1 = jwksJson([rsaJwkJson(kid: 'k1')]);
        var down = false;
        final fetcher = Fetcher((u, i) async {
          if (down) throw const SocketException('unreachable');
          return v1;
        });
        final source = HttpJwksSource.fromJwksUri(
          jwksUri,
          fetch: fetcher.call,
          ttl: const Duration(minutes: 15),
          now: clock.now,
        );

        await source.resolve(headerWith(kid: 'k1')); // load
        down = true;
        clock.advance(const Duration(minutes: 20)); // force a (failing) refresh

        final k1 = await source.resolve(headerWith(kid: 'k1')); // served stale
        expect(k1.kid, 'k1');
      },
    );
  });

  group('cold failure', () {
    test(
      'a cold fetch failure throws JwksUnavailable wrapping the cause',
      () async {
        final fetcher = Fetcher(
          (u, i) async => throw const SocketException('unreachable'),
        );
        final source = HttpJwksSource.fromJwksUri(jwksUri, fetch: fetcher.call);
        await expectLater(
          source.resolve(headerWith(kid: 'k1')),
          throwsA(
            isA<JwksUnavailable>().having(
              (e) => e.cause,
              'cause',
              isA<SocketException>(),
            ),
          ),
        );
      },
    );

    test('a cold malformed JWKS document throws JwksUnavailable', () async {
      final fetcher = Fetcher((u, i) async => 'not a jwks');
      final source = HttpJwksSource.fromJwksUri(jwksUri, fetch: fetcher.call);
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(
          isA<JwksUnavailable>().having(
            (e) => e.cause,
            'cause',
            isA<JwksMalformed>(),
          ),
        ),
      );
    });
  });

  group('rotation', () {
    test('a new kid resolves after refresh; a vanished kid then stops', () async {
      final clock = Clock();
      final v1 = jwksJson([rsaJwkJson(kid: 'k1')]);
      final v2 = jwksJson([rsaJwkJson(kid: 'k2')]); // k1 dropped, k2 added
      final fetcher = Fetcher((u, i) async => i == 0 ? v1 : v2);
      final source = HttpJwksSource.fromJwksUri(
        jwksUri,
        fetch: fetcher.call,
        minRefreshInterval: const Duration(minutes: 5),
        now: clock.now,
      );

      // k1 verifies while it is still in the JWKS.
      expect((await source.resolve(headerWith(kid: 'k1'))).kid, 'k1');
      // k2 is missing -> the miss refreshes to v2, and k2 resolves.
      expect((await source.resolve(headerWith(kid: 'k2'))).kid, 'k2');
      // k1 has now left the fetched set. It is unknown, served from the current
      // cache without a refetch (still within cooldown).
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(isA<JwtUnknownKey>()),
      );
    });

    test(
      'a key unchanged across a refresh keeps the same Jwk instance',
      () async {
        final clock = Clock();
        final v1 = jwksJson([rsaJwkJson(kid: 'k1')]);
        // Same k1 (identical material), plus a new k2.
        final v2 = jwksJson([rsaJwkJson(kid: 'k1'), rsaJwkJson(kid: 'k2')]);
        final fetcher = Fetcher((u, i) async => i == 0 ? v1 : v2);
        final source = HttpJwksSource.fromJwksUri(
          jwksUri,
          fetch: fetcher.call,
          ttl: const Duration(minutes: 15),
          now: clock.now,
        );

        final before = await source.resolve(headerWith(kid: 'k1'));
        clock.advance(const Duration(minutes: 20)); // trigger a TTL refresh
        final after = await source.resolve(headerWith(kid: 'k1'));
        expect(fetcher.count, 2); // a refresh really happened
        expect(identical(before, after), isTrue); // identity preserved
      },
    );

    test(
      'a metadata change (declared alg flip) is NOT reused: a fresh instance',
      () async {
        final clock = Clock();
        // Same kid and material, but the declared alg flips RS256 -> RS512.
        final v1 = jwksJson([rsaJwkJson(kid: 'k1', alg: 'RS256')]);
        final v2 = jwksJson([rsaJwkJson(kid: 'k1', alg: 'RS512')]);
        final fetcher = Fetcher((u, i) async => i == 0 ? v1 : v2);
        final source = HttpJwksSource.fromJwksUri(
          jwksUri,
          fetch: fetcher.call,
          ttl: const Duration(minutes: 15),
          now: clock.now,
        );

        final before = await source.resolve(headerWith(kid: 'k1'));
        expect(before.algorithm, JwsAlgorithm.rs256);
        clock.advance(const Duration(minutes: 20)); // trigger a TTL refresh
        final after = await source.resolve(headerWith(kid: 'k1'));
        expect(fetcher.count, 2);
        // The declaration changed, so the old instance must NOT be reused — the
        // validator's kid↔alg cross-check now sees RS512, not the stale RS256.
        expect(identical(before, after), isFalse);
        expect(after.algorithm, JwsAlgorithm.rs512);
      },
    );
  });

  group('OIDC discovery', () {
    String discoveryDoc(String issuer, String jwksUri) =>
        '{"issuer":"$issuer","jwks_uri":"$jwksUri"}';

    test(
      'extracts jwks_uri from the well-known document and uses it',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        final fetcher = Fetcher(
          (u, i) async => u.path.endsWith('openid-configuration')
              ? discoveryDoc('https://idp.example', 'https://idp.example/keys')
              : body,
        );
        final source = HttpJwksSource.discover(
          issuer: 'https://idp.example',
          fetch: fetcher.call,
        );

        final jwk = await source.resolve(headerWith(kid: 'k1'));
        expect(jwk.kid, 'k1');
        expect(source.resolvedJwksUri, Uri.parse('https://idp.example/keys'));
        expect(
          fetcher.calls.first.toString(),
          'https://idp.example/.well-known/openid-configuration',
        );
        expect(fetcher.calls[1], Uri.parse('https://idp.example/keys'));
      },
    );

    test('an issuer mismatch is a JwksDiscoveryException', () async {
      final fetcher = Fetcher(
        (u, i) async =>
            discoveryDoc('https://attacker.example', 'https://x/keys'),
      );
      final source = HttpJwksSource.discover(
        issuer: 'https://idp.example',
        fetch: fetcher.call,
      );
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(isA<JwksDiscoveryException>()),
      );
    });

    test('a non-JSON discovery document is a JwksDiscoveryException', () async {
      final fetcher = Fetcher((u, i) async => 'not json');
      final source = HttpJwksSource.discover(
        issuer: 'https://idp.example',
        fetch: fetcher.call,
      );
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(isA<JwksDiscoveryException>()),
      );
    });

    test('an unparsable jwks_uri is a JwksDiscoveryException', () async {
      // Dart's Uri.parse is lenient; "http://[invalid" genuinely throws.
      final fetcher = Fetcher(
        (u, i) async => discoveryDoc('https://idp.example', 'http://[invalid'),
      );
      final source = HttpJwksSource.discover(
        issuer: 'https://idp.example',
        fetch: fetcher.call,
      );
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(isA<JwksDiscoveryException>()),
      );
    });

    test(
      'a discovery document without jwks_uri is a JwksDiscoveryException',
      () async {
        final fetcher = Fetcher(
          (u, i) async => '{"issuer":"https://idp.example"}',
        );
        final source = HttpJwksSource.discover(
          issuer: 'https://idp.example',
          fetch: fetcher.call,
        );
        await expectLater(
          source.resolve(headerWith(kid: 'k1')),
          throwsA(isA<JwksDiscoveryException>()),
        );
      },
    );

    test(
      'discovery runs once; a later refresh reuses the cached jwks_uri',
      () async {
        final clock = Clock();
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        var discoveries = 0;
        final fetcher = Fetcher((u, i) async {
          if (u.path.endsWith('openid-configuration')) {
            discoveries++;
            return discoveryDoc(
              'https://idp.example',
              'https://idp.example/keys',
            );
          }
          return body;
        });
        final source = HttpJwksSource.discover(
          issuer: 'https://idp.example',
          fetch: fetcher.call,
          ttl: const Duration(minutes: 15),
          now: clock.now,
        );

        await source.resolve(headerWith(kid: 'k1'));
        clock.advance(const Duration(minutes: 20));
        await source.resolve(headerWith(kid: 'k1')); // TTL refresh
        expect(discoveries, 1); // discovery not repeated
      },
    );
  });

  group('default HttpClient wiring (structural, no network)', () {
    test('the defaults are the documented timeouts and intervals', () {
      final source = HttpJwksSource.fromJwksUri(Uri.parse('https://x/jwks'));
      expect(source.connectTimeout, const Duration(seconds: 5));
      expect(source.totalTimeout, const Duration(seconds: 10));
      expect(source.ttl, const Duration(minutes: 15));
      expect(source.minRefreshInterval, const Duration(minutes: 5));
      expect(source.issuer, isNull);
    });

    test('discover records the issuer and has no jwks_uri until discovery', () {
      final source = HttpJwksSource.discover(issuer: 'https://idp.example');
      expect(source.issuer, 'https://idp.example');
      expect(source.resolvedJwksUri, isNull);
    });
  });

  group('transport security (https enforcement)', () {
    String discoveryDoc(String issuer, String jwksUri) =>
        '{"issuer":"$issuer","jwks_uri":"$jwksUri"}';

    test('a non-loopback http jwks_uri is rejected at construction', () {
      expect(
        () => HttpJwksSource.fromJwksUri(Uri.parse('http://issuer.example/j')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a non-loopback http issuer is rejected at construction', () {
      expect(
        () => HttpJwksSource.discover(issuer: 'http://idp.example'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an issuer with no scheme is rejected at construction', () {
      expect(
        () => HttpJwksSource.discover(issuer: 'idp.example'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a non-http(s) scheme is rejected at construction', () {
      expect(
        () => HttpJwksSource.fromJwksUri(Uri.parse('file:///etc/keys')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('https jwks_uri and issuer are accepted', () {
      expect(
        HttpJwksSource.fromJwksUri(Uri.parse('https://issuer.example/jwks')),
        isA<HttpJwksSource>(),
      );
      expect(
        HttpJwksSource.discover(issuer: 'https://idp.example'),
        isA<HttpJwksSource>(),
      );
    });

    test(
      'loopback http jwks_uri and issuer are accepted (local development)',
      () {
        for (final u in const [
          'http://127.0.0.1:8080/jwks',
          'http://localhost:8080/jwks',
          'http://[::1]:8080/jwks',
          'http://127.9.9.9/jwks', // anywhere in 127.0.0.0/8
        ]) {
          expect(
            HttpJwksSource.fromJwksUri(Uri.parse(u)),
            isA<HttpJwksSource>(),
            reason: u,
          );
        }
        expect(
          HttpJwksSource.discover(issuer: 'http://localhost:8080'),
          isA<HttpJwksSource>(),
        );
      },
    );

    test('a plaintext jwks_uri smuggled into the discovery doc is a '
        'JwksDiscoveryException', () async {
      final fetcher = Fetcher(
        (u, i) async =>
            discoveryDoc('https://idp.example', 'http://idp.example/keys'),
      );
      final source = HttpJwksSource.discover(
        issuer: 'https://idp.example',
        fetch: fetcher.call,
      );
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(isA<JwksDiscoveryException>()),
      );
    });

    test(
      'a loopback http jwks_uri from the discovery doc is accepted',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        final fetcher = Fetcher(
          (u, i) async => u.path.endsWith('openid-configuration')
              ? discoveryDoc('https://idp.example', 'http://127.0.0.1:9/keys')
              : body,
        );
        final source = HttpJwksSource.discover(
          issuer: 'https://idp.example',
          fetch: fetcher.call,
        );
        final jwk = await source.resolve(headerWith(kid: 'k1'));
        expect(jwk.kid, 'k1');
        expect(source.resolvedJwksUri, Uri.parse('http://127.0.0.1:9/keys'));
      },
    );
  });

  group('cold-start throttle', () {
    test(
      'repeated cold failures within the cooldown fetch ONCE and re-surface the '
      'same parked failure, then recover fast once the IdP is back',
      () async {
        final clock = Clock();
        final v1 = jwksJson([rsaJwkJson(kid: 'k1')]);
        var down = true;
        final fetcher = Fetcher((u, i) async {
          if (down) throw const SocketException('unreachable');
          return v1;
        });
        final source = HttpJwksSource.fromJwksUri(
          jwksUri,
          fetch: fetcher.call,
          minRefreshInterval: const Duration(minutes: 5),
          now: clock.now,
        );

        // First cold read: one fetch, fails cold with JwksUnavailable.
        Object? e1;
        try {
          await source.resolve(headerWith(kid: 'k1'));
        } catch (e) {
          e1 = e;
        }
        expect(e1, isA<JwksUnavailable>());
        expect(fetcher.count, 1);

        // Second cold read within the cooldown: NO new fetch, and the very same
        // parked failure object is re-surfaced.
        Object? e2;
        try {
          await source.resolve(headerWith(kid: 'k1'));
        } catch (e) {
          e2 = e;
        }
        expect(
          fetcher.count,
          1,
          reason: 'throttled: the down IdP is not re-hit',
        );
        expect(
          identical(e1, e2),
          isTrue,
          reason: 'the parked failure re-surfaced',
        );

        // Past the cooldown: a fresh attempt is allowed (still down).
        clock.advance(const Duration(minutes: 6));
        await expectLater(
          source.resolve(headerWith(kid: 'k1')),
          throwsA(isA<JwksUnavailable>()),
        );
        expect(fetcher.count, 2);

        // The IdP recovers: the next attempt loads and resolves immediately,
        // and further reads are cache-only (fast recovery, no lingering throttle).
        down = false;
        clock.advance(const Duration(minutes: 6));
        final jwk = await source.resolve(headerWith(kid: 'k1'));
        expect(jwk.kid, 'k1');
        expect(fetcher.count, 3);
        await source.resolve(headerWith(kid: 'k1'));
        expect(fetcher.count, 3, reason: 'healthy again: cache-only');
      },
    );

    test(
      'the first cold load is still exempt: a miss immediately after startup '
      'may refresh within the cooldown window',
      () async {
        // Guards against a regression where stamping the cold *success* would
        // wrongly throttle the first miss-refresh.
        final clock = Clock();
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        final fetcher = Fetcher((u, i) async => body);
        final source = HttpJwksSource.fromJwksUri(
          jwksUri,
          fetch: fetcher.call,
          minRefreshInterval: const Duration(minutes: 5),
          now: clock.now,
        );

        await source.resolve(headerWith(kid: 'k1')); // cold load: fetch #1
        await expectLater(
          source.resolve(headerWith(kid: 'x')), // immediate miss: fetch #2
          throwsA(isA<JwtUnknownKey>()),
        );
        expect(fetcher.count, 2);
      },
    );
  });

  group('response size cap (real HttpServer over loopback)', () {
    // The cap lives in the default HttpClient fetch, so these tests must drive a
    // real socket (a fetch hook would bypass it). Loopback http is permitted by
    // the transport policy, which is what makes an in-process server usable here.
    late HttpServer server;
    late Uri url;

    Future<void> start(void Function(HttpRequest) handler) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(handler);
      url = Uri.parse('http://127.0.0.1:${server.port}/jwks');
    }

    tearDown(() async => server.close(force: true));

    test(
      'a valid JWKS under the cap resolves end-to-end over loopback',
      () async {
        final body = jwksJson([rsaJwkJson(kid: 'k1')]);
        await start((req) {
          req.response
            ..statusCode = HttpStatus.ok
            ..write(body);
          req.response.close();
        });
        final source = HttpJwksSource.fromJwksUri(url);
        final jwk = await source.resolve(headerWith(kid: 'k1'));
        expect(jwk.kid, 'k1');
      },
    );

    test('a body whose declared Content-Length exceeds the cap fails cold '
        '(JwksUnavailable wrapping an HttpException)', () async {
      // One write with a known length => the server sets Content-Length, so
      // the client rejects before reading the body.
      final oversized = List<int>.filled(1024 * 1024 + 4096, 0x61); // > 1 MiB
      await start((req) {
        req.response
          ..statusCode = HttpStatus.ok
          ..add(oversized);
        req.response.close();
      });
      final source = HttpJwksSource.fromJwksUri(url);
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(
          isA<JwksUnavailable>().having(
            (e) => e.cause,
            'cause',
            isA<HttpException>(),
          ),
        ),
      );
    });

    test('a chunked (no Content-Length) body over the cap fails cold via the '
        'streaming check', () async {
      await start((req) {
        req.response
          ..statusCode = HttpStatus.ok
          ..headers.chunkedTransferEncoding = true;
        // 32 chunks of 64 KiB = 2 MiB, streamed with no declared length: the
        // client aborts once the running total passes the cap.
        final chunk = List<int>.filled(64 * 1024, 0x61);
        for (var i = 0; i < 32; i++) {
          req.response.add(chunk);
        }
        req.response.close();
      });
      final source = HttpJwksSource.fromJwksUri(url);
      await expectLater(
        source.resolve(headerWith(kid: 'k1')),
        throwsA(
          isA<JwksUnavailable>().having(
            (e) => e.cause,
            'cause',
            isA<HttpException>(),
          ),
        ),
      );
    });
  });
}
