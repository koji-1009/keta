import 'package:keta/keta.dart';
import 'env.dart';

/// Who the request is. A verifier puts this in the request store; handlers read
/// it back. This is the canonical way middleware hands data to a handler: a
/// typed [Key], not an untyped bag and not a field smuggled onto the env (which
/// is per-isolate, not per-request).
final principal = Key<Principal>('principal');

/// The authenticated caller.
class Principal {
  const Principal(this.id, {this.admin = false});
  final String id;
  final bool admin;
}

/// The schemes a route gets when it declares nothing.
///
/// One constant, read in two places — `OpenApi.fromRoutes(security:)` for the
/// document and `SecurityPolicy.defaults` for the runtime gate — so the contract
/// and the guard cannot drift apart. Secure by default: a route is protected
/// unless it says otherwise, so forgetting to think about auth fails closed.
const apiDefaults = [bearer];

/// Demo credentials. A real app checks a JWT signature or asks an IdP; keta
/// ships no auth, and this is the app's business by design.
const _tokens = {
  't-admin': Principal('ada', admin: true),
  't-user': Principal('bo'),
};
const _apiKeys = {'k-metrics'};

/// The runtime half of the declarations. Verification is app code; keta only
/// matches a route's declared schemes against these.
SecurityPolicy<Env> securityPolicy() => SecurityPolicy<Env>(
  defaults: apiDefaults,
  verifiers: {
    // Named for the scheme, so `RouteDoc(security: [bearer])` finds it.
    bearer.name: (c) {
      final header = c.header('authorization');
      if (header == null || !header.startsWith('Bearer ')) return false;
      final who = _tokens[header.substring(7)];
      if (who == null) return false;
      // Authentication only. What `who` is allowed to do is the handler's or an
      // ordinary middleware's business, not the gate's.
      c.set(principal, who);
      return true;
    },
    apiKey.name: (c) => _apiKeys.contains(c.header('x-api-key')),
  },
);

/// The body `recover()` renders for any [KetaException]: `{"error": message}`.
/// A status a route can really return belongs in its RouteDoc.responses, or the
/// document is only telling half the truth about what a client must handle.
const errorSchema = Schema('Error', {
  'type': 'object',
  'required': ['error'],
  'properties': {
    'error': {'type': 'string'},
  },
});

/// Authorization, which is deliberately not the security gate's job: the gate
/// answers "who are you", this answers "may you". Ordinary middleware.
///
/// [principal] is read with tryGet, not get: a route reachable through a scheme
/// whose verifier sets no principal (apiKey, here) would otherwise crash rather
/// than refuse. Absent principal is not an admin, and that is the whole rule.
Middleware<Env> requireAdmin() => (c, next) {
  final who = c.tryGet(principal);
  if (who == null || !who.admin) {
    throw const Forbidden('admin only');
  }
  return next(c);
};
