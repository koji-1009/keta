import 'dart:math';

import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'env.dart';

/// The authenticated caller's role, set by whichever verifier admitted the
/// request (bearer or cookie session alike) and read downstream with
/// `c.tryGet(authRole)`.
final authRole = Key<String>('auth.role');

// A stand-in token table. A real app verifies a JWT or a session here.
const _tokens = {'admin-token': 'admin', 'member-token': 'member'};

/// Demo login credentials for the cookie-session flow below, keyed by the
/// same roles `_tokens` grants over bearer — a real app checks a password
/// hash against a user store here; this table is the same kind of stand-in
/// `_tokens` is for bearer, just reached by `/login` instead of a header.
const _credentials = {'admin': 'admin-pass', 'member': 'member-pass'};

/// keta_openapi ships `bearer` and `apiKey`; a cookie-carried credential is
/// documented in OpenAPI the same way `apiKey` is — a named location, not a
/// bearer scheme — so this reference mints its own scheme rather than
/// stretching `apiKey`'s "header" semantics to fit a cookie. `in: 'cookie'` is
/// exactly what OpenAPI's `apiKey` type provides for this case.
const cookieAuth = SecurityScheme('cookieAuth', {
  'type': 'apiKey',
  'in': 'cookie',
  'name': 'sid',
});

final _sessionRandom = Random.secure();

/// A random session id: 16 secure-random bytes as lowercase hex, the same
/// idiom `App._reqId` uses for request ids. Unguessable is the whole point —
/// a session store keyed by anything predictable is a hijack waiting to
/// happen.
String _newSessionId() {
  final bytes = List<int>.generate(16, (_) => _sessionRandom.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Verifies [username]/[password] against the demo credential table and, on
/// success, mints a session id and stores `sid -> role` in [env]'s store —
/// the credential check and the session-store write both stay app code, same
/// as the bearer token table above. Returns the new session id, or null on
/// invalid credentials, for `/login` to turn into a cookie or a 401.
String? login(Env env, String username, String password) {
  if (_credentials[username] != password) return null;
  final sid = _newSessionId();
  env.sessions[sid] = username;
  return sid;
}

/// Ends a session by removing [sid] from [env]'s store. A null or already-
/// removed [sid] is not an error — logging out twice is still logged out.
void logout(Env env, String? sid) {
  if (sid != null) env.sessions.remove(sid);
}

/// The security policy, wired once via `enforceSecurity`. keta owns only the
/// plumbing that matches a route's declared schemes to these verifiers; the
/// credential check itself is app code, so "keta ships no auth" holds. The
/// bearer verifier resolves the token to a role; the cookie verifier resolves
/// a session id the same way. Both store the result for the role guard
/// downstream — same side-effect pattern, two different credential shapes.
///
/// `defaults: [bearer]` makes a route that declares no security fail closed —
/// forgetting to think about auth is a 401, not a silent public route. A
/// route meant to be public says so explicitly (`RouteDoc(security: const
/// [])`), which is what `/public` does.
final securityPolicy = SecurityPolicy<Env>(
  defaults: const [bearer],
  verifiers: {
    'bearer': (c) {
      final header = c.header('authorization') ?? '';
      const scheme = 'Bearer ';
      final token = header.startsWith(scheme)
          ? header.substring(scheme.length)
          : '';
      final role = _tokens[token];
      if (role == null) return false;
      c.set(authRole, role);
      return true;
    },
    // Same side-effect pattern as bearer above: on success, resolve to a role
    // and c.set it for the role guard. The only difference is where the
    // credential travels (a `Cookie` header, parsed by `c.cookie`) and where
    // it resolves (the app-owned session store on Env, not a fixed table).
    cookieAuth.name: (c) {
      final sid = c.cookie('sid');
      if (sid == null) return false;
      final role = c.env.sessions[sid];
      if (role == null) return false;
      c.set(authRole, role);
      return true;
    },
  },
);

/// Requires the authenticated caller to hold [required]; otherwise 403
/// ([Forbidden]). Runs after `enforceSecurity` has set the role.
///
/// [authRole] is read with `tryGet`, not `get`: an unset role is an expected
/// authentication outcome (a scheme admitted the request without one, or this
/// middleware ends up on a route reachable through one that doesn't set it),
/// not a programming defect — it must 403 here, not crash the process with a
/// 500 from `get`'s `StateError`. Absent role matches no required role, and
/// that is the whole rule.
Middleware<E> requireRole<E>(String required) => (c, next) {
  if (c.tryGet(authRole) != required) {
    throw Forbidden('requires the "$required" role');
  }
  return next(c);
};
