import 'package:keta/keta.dart';
import 'package:keta_oidc/keta_oidc.dart';

/// The application environment: the constructor graph that carries the app's
/// dependencies. keta reaches [log] structurally.
///
/// [jwks] and [validator] are the two objects `oidc()` verifies every Bearer
/// token against (see lib/app.dart's `buildApp`) — the same C-3
/// resource-ownership pattern every other example's `Env` uses for its own
/// dependencies (`../register`'s `db`, `../auth`'s `sessions`). They are built
/// once, from the *same* construction call, in whichever caller assembles this
/// `Env`:
///
/// * `bin/main.dart` builds `HttpJwksSource.discover(issuer: ...)` and a
///   [JwtValidator] over `BoringSslVerifier` — the real thing, reached over the
///   network.
/// * `test/oidc_example_test.dart` builds a `StaticJwks` over keys minted by
///   `package:keta_native/testing.dart` and a [JwtValidator] over the same
///   `BoringSslVerifier` — real crypto, no network.
///
/// Neither object owns a resource this `Env` must close: `HttpJwksSource`
/// opens a fresh, short-lived `HttpClient` per fetch rather than holding a
/// connection open, and `BoringSslVerifier`'s key cache is garbage-collected
/// with the verifier itself. That is why, unlike
/// `../register`'s or `../auth`'s `Env`, this one implements no `Disposable` —
/// there is nothing here that outlives a request and needs an explicit close.
class Env implements HasLog {
  Env(this.log, this.jwks, this.validator);

  @override
  final Log log;

  /// The key source `oidc()` resolves a token's `kid` against.
  final JwksSource jwks;

  /// The signature/claims policy `oidc()` enforces — issuer, audience,
  /// algorithm allowlist, and the `BoringSslVerifier` (or, in tests, a
  /// [JwtValidator] over the same verifier against test keys).
  final JwtValidator validator;

  /// The tiny domain state `/api/reports` demonstrates: report names visible
  /// to any caller holding the `reports:read` scope. `requireScopes()` (see
  /// lib/app.dart) is the whole access-control story here — by the time a
  /// handler reads this, the caller has already proven the scope, so there is
  /// nothing left to check.
  final List<String> reports = const ['2026-q1-summary', '2026-q2-summary'];
}
