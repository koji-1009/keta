library;

import 'dart:async';

import 'app.dart';
import 'context.dart';
import 'order.dart';
import 'response.dart';
import 'route_doc.dart';

/// The runtime counterpart of the `security` declarations: the schemes required
/// where a route declares none, plus a per-scheme credential check. Credential
/// verification itself is app code — keta owns only the plumbing that matches a
/// route's declared schemes against these verifiers, so "keta ships no auth"
/// stands.
class SecurityPolicy<E> {
  const SecurityPolicy({this.defaults = const [], this.verifiers = const {}});

  /// Schemes required for a route whose `RouteDoc.security` is null (mirrors the
  /// `OpenApi.fromRoutes(security:)` default).
  final List<SecurityScheme> defaults;

  /// Per-scheme-name credential check: return true to admit. A verifier may set
  /// request state (e.g. `c.set(principal, ...)`) as a side effect on success.
  final Map<String, FutureOr<bool> Function(Context<E>)> verifiers;
}

/// Middleware that enforces a route's declared security. Wire it once, upstream
/// (`app.use(enforceSecurity(policy))`).
///
/// It reads the matched route's security from `c.routeDoc`: `null` follows
/// [SecurityPolicy.defaults], an empty list (explicitly public) is admitted
/// without a check, and a non-empty list is OR-combined — any passing verifier
/// admits, all failing raises [Unauthorized]. It performs authentication only;
/// authorization (roles) stays ordinary app middleware.
///
/// It stays on the synchronous path (no [Future] allocated) when the route is
/// public or a verifier answers synchronously, so a public request pays nothing.
Middleware<E> enforceSecurity<E>(SecurityPolicy<E> policy) =>
    ordered((Context<E> c, Handler<E> next) {
      final required = c.routeDoc?.security ?? policy.defaults;
      if (required.isEmpty) return next(c);
      return _admit(c, next, required, policy, 0);
    }, KetaOrder.authenticate);

/// Tries each declared scheme's verifier in order (OR): the first to admit runs
/// [next]; if none does, the request is unauthenticated. Recurses synchronously
/// until a verifier actually returns a [Future].
FutureOr<Response> _admit<E>(
  Context<E> c,
  Handler<E> next,
  List<SecurityScheme> required,
  SecurityPolicy<E> policy,
  int i,
) {
  if (i == required.length) {
    throw const Unauthorized('authentication required');
  }
  final verify = policy.verifiers[required[i].name];
  if (verify == null) return _admit(c, next, required, policy, i + 1);
  final result = verify(c);
  if (result is Future<bool>) {
    return result.then(
      (ok) => ok ? next(c) : _admit(c, next, required, policy, i + 1),
    );
  }
  return result ? next(c) : _admit(c, next, required, policy, i + 1);
}
