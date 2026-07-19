library;

import 'package:keta/keta.dart';

import '../jwks/http_jwks_source.dart';
import '../jwks/jwks_source.dart';
import '../jwt/jws.dart';
import '../jwt/rejection.dart';
import '../jwt/validator.dart';
import 'principal.dart';

/// Bearer-JWT authentication middleware (RFC 6750). It extracts the `Bearer`
/// token from `Authorization`, resolves its key through [jwks], validates it
/// with [validator], and on success injects an [OidcPrincipal] into the request
/// [Context] (read it with `c.get(oidcPrincipal)`) before calling the handler.
/// A request that fails is answered here, never reaching the handler.
///
/// ## One obvious wiring
///
/// [jwks] and [validator] are the two objects the app owns (in its `Env`, the
/// C-3 resource-ownership pattern): a [JwksSource] — `StaticJwks` or the
/// caching, single-flight `HttpJwksSource` — and a [JwtValidator] carrying the
/// [SignatureVerifier] and the issuer/audience/algorithm/leeway policy. There is
/// deliberately no second way to configure this; the validator *is* the bundle
/// of verification parameters.
///
/// ## Why it returns Responses instead of throwing
///
/// keta core's `recover()` renders a thrown `KetaException` as
/// `Response.json({'error': ...})` — a body, but **no headers**. RFC 6750
/// requires a `WWW-Authenticate` header on every 401/403 here, which that path
/// cannot carry, so this middleware builds and returns the Responses itself
/// (verified against `recover()` — `KetaException` has no header channel).
///
/// ## The two 401 shapes (RFC 6750 §3)
///
/// * **No Bearer credentials** — no `Authorization` header, or a different scheme
///   (e.g. `Basic`): a bare `WWW-Authenticate: Bearer` with **no** `error` code,
///   because no Bearer token was presented to be judged.
/// * **Bearer credentials present but bad** — a malformed header, or a token that
///   fails any check: `WWW-Authenticate: Bearer error="invalid_token"` plus an
///   `error_description` of the rejection *category* — never a claim value or
///   key material, so it cannot be used as an oracle.
///
/// ## Non-token failures
///
/// * [JwksUnavailable] → **503**, with no `WWW-Authenticate` error code: the
///   token was never judged because the key source is down. Not the client's
///   fault, not an auth challenge.
/// * [JwksDiscoveryException] → **500**, logged as an error: a server-side
///   trust/configuration failure (a discovery document whose issuer did not
///   match, or was malformed), neither transient nor the client's fault.
///
/// ## Composition
///
/// Place `oidc()` under `timeout()` / `rateLimit()` (they wrap it) and in front
/// of a route — including an SSE (`c.sse`) or WebSocket (`Response.upgrade`)
/// route: verification runs and can answer 401 *before* the handler ever builds
/// the upgrade value, because the upgrade is an ordinary return value the auth
/// gate sees first. Pair with keta_openapi by declaring `bearer` on a route's
/// `RouteDoc` for the OpenAPI projection and enforcing it at runtime with
/// `oidc()`; the two are independent (openapi documents, `oidc()` enforces — and
/// owns the RFC 6750 challenge a boolean `enforceSecurity` verifier cannot
/// express).
Middleware<E> oidc<E>({
  required JwksSource jwks,
  required JwtValidator validator,
}) {
  return (Context<E> c, Handler<E> next) async {
    final bearer = _extractBearer(c.header('authorization'));
    switch (bearer) {
      case _NoBearer():
        return _bareChallenge();
      case _BadBearer(:final description):
        return _invalidToken(description);
      case _Token(:final value):
        final OidcPrincipal principal;
        try {
          final jws = Jws.parse(value);
          final key = await jwks.resolve(jws.header);
          final claims = validator.validate(jws, key);
          principal = OidcPrincipal.fromClaims(claims);
        } on JwtRejection catch (rejection) {
          return _invalidToken(_describeRejection(rejection));
        } on JwksUnavailable catch (e) {
          // The key source is down and had nothing cached — the token was never
          // judged. 503, no challenge: this is not the client's failure. Log it
          // before returning: an IdP/key-source outage is exactly what an
          // operator must see, and the exception's `cause` goes nowhere else
          // (we return a Response, so recover() never logs it). `warn`, not
          // `error` — a transient outage is an expected class, not an incident,
          // mirroring keta's transient-unavailability posture — and the 503
          // answer itself is unchanged.
          c.log.warn(e.message, {if (e.cause != null) 'cause': '${e.cause}'});
          return Response.json({
            'error': 'key source unavailable',
          }, status: 503);
        } on JwksDiscoveryException catch (e, st) {
          // A trust/config failure (issuer mismatch or a malformed discovery
          // document). Server-side and not transient; surface a 500 and log it
          // as an incident, leaking no detail to the client.
          c.log.error('OIDC discovery failed', e, st);
          return Response.json({'error': 'internal server error'}, status: 500);
        }
        c.set(oidcPrincipal, principal);
        return next(c);
    }
  };
}

/// Requires that the authenticated caller hold **every** scope in [scopes]
/// (AND semantics). Place it after [oidc] on the routes that need it. On a
/// missing scope it answers **403** with a `WWW-Authenticate: Bearer
/// error="insufficient_scope"` challenge whose `scope` parameter names the
/// required scopes, space-joined (RFC 6750 §3.1), plus a JSON body.
///
/// AND is the only mode: an OR requirement composes out of it at the app level
/// (branch and call the appropriate `requireScopes`), so no `mode` flag is
/// added here.
///
/// Running this with **no** [OidcPrincipal] in the [Context] is an author defect
/// — `requireScopes` was placed before (or without) `oidc()` — and throws
/// [StateError], not a 401. A 401 would tell a client "authenticate" for what is
/// really a middleware-ordering bug in the server; failing loudly at the seam
/// surfaces the real cause instead of masking it as a client problem.
///
/// [scopes] is validated at **factory time** (when `requireScopes([...])` is
/// called, not per request), throwing [ArgumentError] on an authoring defect:
/// an **empty list** (a gate that enforces nothing yet reads like protection),
/// or a scope that is empty or carries a character outside the RFC 6749
/// `scope-token` charset (printable ASCII except space, `"`, and `\`). The last
/// is also a header-safety guard: each scope is interpolated verbatim into the
/// quoted `scope` parameter of the `WWW-Authenticate` header, and these are
/// exactly the characters that would corrupt it. Scopes are author-controlled,
/// so this is an authoring check, not request validation.
Middleware<E> requireScopes<E>(List<String> scopes) {
  if (scopes.isEmpty) {
    throw ArgumentError.value(
      scopes,
      'scopes',
      'must not be empty — a scope gate that requires nothing enforces nothing',
    );
  }
  for (final scope in scopes) {
    _checkScopeToken(scope);
  }
  return (Context<E> c, Handler<E> next) {
    final principal = c.tryGet(oidcPrincipal);
    if (principal == null) {
      throw StateError(
        'requireScopes() found no OidcPrincipal in the request: it must be '
        'placed after oidc() on the route',
      );
    }
    for (final scope in scopes) {
      if (!principal.scopes.contains(scope)) {
        return _insufficientScope(scopes);
      }
    }
    return next(c);
  };
}

/// Validates one required scope token at factory time, throwing [ArgumentError]
/// on an authoring defect. A scope must be a non-empty RFC 6749 `scope-token`:
/// `1*( %x21 / %x23-5B / %x5D-7E )` — printable ASCII excluding space (`%x20`),
/// `"` (`%x22`), and `\` (`%x5C`). Rejecting the latter two also keeps the
/// verbatim interpolation into the quoted `WWW-Authenticate` `scope` parameter
/// injection-safe.
void _checkScopeToken(String scope) {
  if (scope.isEmpty) {
    throw ArgumentError.value(scope, 'scopes', 'a scope must not be empty');
  }
  for (var i = 0; i < scope.length; i++) {
    final c = scope.codeUnitAt(i);
    final ok =
        c == 0x21 || (c >= 0x23 && c <= 0x5B) || (c >= 0x5D && c <= 0x7E);
    if (!ok) {
      throw ArgumentError.value(
        scope,
        'scopes',
        'contains a character outside the RFC 6749 scope-token charset '
            '(printable ASCII except space, \'"\', and backslash) at index $i',
      );
    }
  }
}

/// The result of reading the `Authorization` header for a Bearer token.
sealed class _Bearer {
  const _Bearer();
}

/// No Bearer credentials were presented (absent header, or a non-Bearer scheme)
/// → the bare challenge.
final class _NoBearer extends _Bearer {
  const _NoBearer();
}

/// Bearer scheme was used but the credentials are unusable (empty, or more than
/// one token) → `invalid_token` with [description].
final class _BadBearer extends _Bearer {
  const _BadBearer(this.description);
  final String description;
}

/// A single well-formed Bearer token was extracted (not yet validated).
final class _Token extends _Bearer {
  const _Token(this.value);
  final String value;
}

/// Parses an `Authorization` header value into a [_Bearer] result (RFC 6750
/// §2.1): the scheme match is case-insensitive, and the credentials are exactly
/// one whitespace-delimited token.
_Bearer _extractBearer(String? header) {
  if (header == null) return const _NoBearer();
  final value = header.trim();

  // Scheme = everything up to the first run of whitespace.
  var i = 0;
  while (i < value.length && value[i] != ' ' && value[i] != '\t') {
    i++;
  }
  final scheme = value.substring(0, i);
  if (scheme.toLowerCase() != 'bearer') {
    // Absent-here: a different scheme (Basic, …) is not Bearer credentials, so
    // it earns the bare challenge, not an invalid_token.
    return const _NoBearer();
  }

  final credentials = value.substring(i).trim();
  if (credentials.isEmpty) {
    return const _BadBearer('the Bearer credentials are empty');
  }
  if (credentials.contains(' ') || credentials.contains('\t')) {
    return const _BadBearer('the Bearer credentials are not a single token');
  }
  return _Token(credentials);
}

/// Maps a [JwtRejection] to a client-safe `error_description` **category** — an
/// exhaustive switch, so a new rejection type forces a mapping decision here
/// rather than defaulting to a leaky or wrong message. Every reason is a 401
/// `invalid_token`; only the description differs, and none echoes a claim value
/// or key material.
String _describeRejection(JwtRejection rejection) => switch (rejection) {
  JwtMalformed() => 'the token is malformed',
  JwtAlgorithmNotAllowed() => 'the token algorithm is not allowed',
  JwtBadSignature() => 'the token signature is invalid',
  JwtExpirationRequired() => 'the token has no expiration',
  JwtExpired() => 'the token is expired',
  JwtNotYetValid() => 'the token is not yet valid',
  JwtIssuerMismatch() => 'the token issuer is not accepted',
  JwtAudienceMismatch() => 'the token audience is not accepted',
  JwtUnknownKey() => 'the token key is not recognized',
};

/// 401 with a bare `WWW-Authenticate: Bearer` — no Bearer token was presented.
Response _bareChallenge() => Response.json(
  {'error': 'authentication required'},
  status: 401,
  headers: {
    'www-authenticate': const ['Bearer'],
  },
);

/// 401 with `error="invalid_token"` and [description].
Response _invalidToken(String description) => Response.json(
  {'error': description},
  status: 401,
  headers: {
    'www-authenticate': [
      'Bearer error="invalid_token", error_description="$description"',
    ],
  },
);

/// 403 with `error="insufficient_scope"` naming the [required] scopes.
Response _insufficientScope(List<String> required) => Response.json(
  {'error': 'insufficient_scope'},
  status: 403,
  headers: {
    'www-authenticate': [
      'Bearer error="insufficient_scope", scope="${required.join(' ')}"',
    ],
  },
);
