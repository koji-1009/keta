library;

import 'package:keta/keta.dart';

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
    this.requestBodyType = 'application/json',
    this.summary,
    this.responses,
    this.security,
    this.query,
  });

  /// The schema of the 200 response body.
  final Schema? response;

  /// The schema of the request body.
  final Schema? requestBody;

  /// The media type of [requestBody], projected as-is onto OpenAPI's
  /// `requestBody.content`. Defaults to `application/json`; set
  /// `multipart/form-data` for an upload so the contract tells the truth about
  /// what the route consumes.
  final String requestBodyType;

  final String? summary;

  /// Responses for statuses other than 200.
  final Map<int, Schema>? responses;

  /// The security schemes that satisfy this route, OR-combined (any one
  /// suffices). `null` follows the global default passed to
  /// `OpenApi.fromRoutes`; an empty list declares the route explicitly public,
  /// overriding that default.
  final List<SecurityScheme>? security;

  /// Query-parameter declarations, projected to OpenAPI `in: query`. Runtime
  /// required-ness is not gated here — it is expressed by the handler's accessor
  /// choice (`c.query` = 400 on absence / `c.tryQuery` = optional).
  final List<QueryParam>? query;

  /// Every schema this doc references, for transitive component collection.
  Iterable<Schema> get schemas => [
    ?response,
    ?requestBody,
    ...?responses?.values,
  ];
}

/// A query-parameter declaration. No new vocabulary — a [Capture] is reused for
/// its `parse` (unused here) and its `schema` fragment, which projects onto the
/// OpenAPI `in: query` parameter as-is.
final class QueryParam {
  const QueryParam(this.name, this.capture, {this.required = false});
  final String name;
  final Capture<Object?> capture;
  final bool required;
}
