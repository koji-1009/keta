import 'package:keta/keta.dart';

/// The authenticated caller's role, set by [auth] and read downstream with
/// `c.get(authRole)`. keta ships no auth — this is ordinary app middleware
/// built on the Key + Context primitives the framework already provides.
final authRole = Key<String>('auth.role');

// A stand-in token table. A real app verifies a JWT or a session here; the
// shape of the middleware is the same.
const _tokens = {'admin-token': 'admin', 'member-token': 'member'};

/// Bearer-token authentication: reads `Authorization: Bearer <token>`, resolves
/// the caller's role, and stores it under [authRole]. A missing or unknown
/// token is a 401 ([Unauthorized]).
Middleware<E> auth<E>() => (c, next) {
  final header = c.header('authorization') ?? '';
  const scheme = 'Bearer ';
  final token = header.startsWith(scheme)
      ? header.substring(scheme.length)
      : '';
  final resolved = _tokens[token];
  if (resolved == null) {
    throw const Unauthorized('missing or invalid bearer token');
  }
  c.set(authRole, resolved);
  return next(c);
};

/// Requires the authenticated caller to hold [required]; otherwise 403
/// ([Forbidden]). Register it after [auth] so the role is already set.
Middleware<E> requireRole<E>(String required) => (c, next) {
  if (c.get(authRole) != required) {
    throw Forbidden('requires the "$required" role');
  }
  return next(c);
};
