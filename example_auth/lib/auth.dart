import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'env.dart';

/// The authenticated caller's role, set by the bearer verifier and read
/// downstream with `c.get(authRole)`.
final authRole = Key<String>('auth.role');

// A stand-in token table. A real app verifies a JWT or a session here.
const _tokens = {'admin-token': 'admin', 'member-token': 'member'};

/// The security policy, wired once via `enforceSecurity`. keta owns only the
/// plumbing that matches a route's declared schemes to these verifiers; the
/// credential check itself is app code, so "keta ships no auth" holds. The
/// bearer verifier resolves the token to a role and stores it for the role
/// guard downstream.
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
  },
);

/// Requires the authenticated caller to hold [required]; otherwise 403
/// ([Forbidden]). Runs after `enforceSecurity` has set the role.
Middleware<E> requireRole<E>(String required) => (c, next) {
  if (c.get(authRole) != required) {
    throw Forbidden('requires the "$required" role');
  }
  return next(c);
};
