import 'dart:convert';
import 'dart:typed_data';

import 'package:keta/keta.dart';
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'env.dart';

/// Builds the fully-configured application: a public route, a Bearer-gated
/// `/api` subtree, and a `requireScopes()`-guarded `/api/reports` beside it.
///
/// [jwks] and [validator] are the exact objects `oidc()` is built from — the
/// same instances the caller also hands to [Env] (see lib/env.dart's doc), so
/// the app that answers a request and the `Env` that request carries agree by
/// construction, never by convention.
///
/// `timeout()`/`rateLimit()` are not wired here (this example stays focused on
/// the auth gate), but they compose exactly where `examples/register`'s
/// `buildApp` documents: above `oidc()`/`recover()` if they only decorate
/// responses (they don't — both throw), so in practice both sit *below*
/// `recover()`, same as `oidc()` itself. A per-IP `rateLimit()` would sit
/// *before* `oidc()` in the `/api` group (a flood is refused before
/// authentication work is spent); a per-principal one would sit *after* it
/// (there is no principal to key on until `oidc()` has run).
App<Env> buildApp({required JwksSource jwks, required JwtValidator validator}) {
  final app = App<Env>()
    ..use(accessLog())
    ..use(recover());

  app.get(
    '/public',
    (c) => c.json({'message': 'no token needed'}),
    doc: const RouteDoc(
      success: Success(),
      summary: 'A public route',
      security: [],
    ),
  );

  // Every route in this group sits behind oidc(): a missing or bad Bearer
  // token is answered here, with the RFC 6750 challenge, before any handler
  // (including the SSE one below) ever runs.
  final api = app.group('/api')..use(oidc(jwks: jwks, validator: validator));

  api.get(
    '/me',
    _meHandler,
    doc: const RouteDoc(
      success: Success(schema: _principalSchema),
      summary: 'The authenticated caller',
      description:
          'sub, granted scopes, and the "org" claim read straight from the '
          'validated token\'s raw claim set.',
      security: [bearer],
    ),
  );

  // The streaming route lives under the SAME oidc() as /me — the point being
  // made here: because oidc() answers before the handler is ever called, an
  // unauthenticated request never reaches c.sse, so a rejected caller gets a
  // 401 JSON body, not a half-open text/event-stream connection.
  api.get(
    '/me/events',
    (c) {
      final principal = c.get(oidcPrincipal);
      return c.sse(
        _ticks(principal.subject ?? '(no sub)'),
        keepAlive: const Duration(seconds: 15),
      );
    },
    doc: const RouteDoc(
      success: Success(schema: _tickSchema, contentType: 'text/event-stream'),
      summary: 'A tick feed behind the same gate as /me',
      description:
          'Proves auth-before-stream: the Bearer check runs and can 401 '
          'before this handler — and therefore the stream — ever starts.',
      security: [bearer],
      tags: ['streaming'],
      operationId: 'streamTicks',
    ),
  );

  // A second group, not a nested one — keta's groups are prefixes with their
  // own middleware list, not a tree (see keta_auth_example's /admin for the
  // same shape). requireScopes() only belongs on this subtree, so it gets its
  // own oidc() + requireScopes() pair rather than widening /api's.
  final reports = app.group('/api/reports')
    ..use(oidc(jwks: jwks, validator: validator))
    ..use(requireScopes(['reports:read']));

  reports.get(
    '/',
    (c) => c.json({'reports': c.env.reports}),
    doc: const RouteDoc(
      success: Success(schema: _reportsSchema),
      summary: 'Reports, gated on the "reports:read" scope',
      security: [bearer],
    ),
  );

  return app;
}

Response _meHandler(Context<Env> c) {
  final principal = c.get(oidcPrincipal);
  return c.json({
    'sub': principal.subject,
    'scopes': principal.scopes.toList()..sort(),
    // claims.raw is where any application/custom claim lives — this layer
    // only lifts the registered ones (iss/sub/aud/exp/nbf/iat) to typed
    // fields (see JwtClaims). "org" is a stand-in for whatever your IdP
    // actually mints (a tenant id, a department, ...).
    'org': principal.claims.raw['org'],
  });
}

/// A tick every [keepAlive]-scale interval, carrying the caller's own `sub` —
/// enough to show a live authenticated feed without inventing a domain. Built
/// on `Stream.periodic(...).map(...)`, not an `async*` generator: cancelling
/// the subscription cancels the periodic `Timer` synchronously, so there is no
/// analogue of the `await-for`-parked-generator leak `../auth`'s
/// `sessionEvents` doc warns about.
Stream<SseEvent> _ticks(String sub) => Stream.periodic(
  const Duration(seconds: 15),
  (n) => SseEvent(jsonEncode({'tick': n + 1, 'sub': sub}), event: 'tick'),
);

const _principalSchema = Schema('Principal', {
  'type': 'object',
  'required': ['sub', 'scopes'],
  'properties': {
    'sub': {'type': 'string'},
    'scopes': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'org': {'type': 'string'},
  },
});

const _tickSchema = Schema('Tick', {
  'type': 'object',
  'required': ['tick', 'sub'],
  'properties': {
    'tick': {'type': 'integer'},
    'sub': {'type': 'string'},
  },
});

const _reportsSchema = Schema('Reports', {
  'type': 'object',
  'required': ['reports'],
  'properties': {
    'reports': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
});

/// The OpenAPI document for [buildApp]. Built with a [StaticJwks] (empty — no
/// key ever needs to be resolved to walk the route table) and a throwaway
/// [JwtValidator], so emitting the document needs neither the network
/// [HttpJwksSource.discover] would reach nor real signing keys — the document
/// is a shadow of the routes, not of the crypto.
OpenApi buildOpenApi() => OpenApi.fromRoutes(
  buildApp(
    jwks: StaticJwks.fromJson(const {'keys': <Object?>[]}),
    validator: JwtValidator(
      verifier: const _UnusedVerifier(),
      algorithms: {JwsAlgorithm.rs256},
      issuer: 'unused',
      audience: 'unused',
    ),
  ).routes,
  title: 'keta oidc example',
  version: '0.1.0',
);

/// A [SignatureVerifier] that is never called: [buildOpenApi] only walks the
/// route table (each route's `doc`), never dispatches a request, so no
/// signature is ever verified against this validator.
final class _UnusedVerifier implements SignatureVerifier {
  const _UnusedVerifier();

  @override
  bool verify({
    required Jwk key,
    required JwsAlgorithm algorithm,
    required Uint8List signingInput,
    required Uint8List signature,
  }) => throw StateError(
    'buildOpenApi() never dispatches a request; this verifier must never be '
    'called',
  );
}
