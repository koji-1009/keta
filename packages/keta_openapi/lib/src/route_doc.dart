library;

import 'schema.dart';

/// A named OpenAPI security scheme, carried as data (the same shape as
/// [Schema]). Referenced from [RouteDoc.security]; the walker collects it
/// transitively into `components/securitySchemes` — the projection travels as
/// data, never inferred from middleware.
final class SecurityScheme {
  const SecurityScheme(this.name, this.json);
  final String name;
  final Map<String, Object?> json;
}

/// HTTP bearer authentication (`Authorization: Bearer <token>`).
const bearer = SecurityScheme('bearer', {'type': 'http', 'scheme': 'bearer'});

/// An API key carried in the `X-API-Key` request header.
const apiKey = SecurityScheme('apiKey', {
  'type': 'apiKey',
  'in': 'header',
  'name': 'X-API-Key',
});

/// Per-route documentation, passed to a route as its opaque `doc` and read back
/// here when emitting OpenAPI.
class RouteDoc {
  const RouteDoc({
    this.response,
    this.requestBody,
    this.summary,
    this.responses,
    this.security,
  });

  /// The schema of the 200 response body.
  final Schema? response;

  /// The schema of the request body.
  final Schema? requestBody;

  final String? summary;

  /// Responses for statuses other than 200.
  final Map<int, Schema>? responses;

  /// The security schemes that satisfy this route, OR-combined (any one
  /// suffices). `null` follows the global default passed to
  /// `OpenApi.fromRoutes`; an empty list declares the route explicitly public,
  /// overriding that default.
  final List<SecurityScheme>? security;

  /// Every schema this doc references, for transitive component collection.
  Iterable<Schema> get schemas => [
    ?response,
    ?requestBody,
    ...?responses?.values,
  ];
}
