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

/// What a route answers with when it succeeds: the status, and the body when it
/// has one to document.
///
/// Required on every [RouteDoc], so a contract declaring no success cannot be
/// written — the shape carries what a check would otherwise have to. The
/// emitter used to fabricate a 200 whenever nothing was declared, and a guess is
/// right only by luck: `POST /users` answers 201 and `DELETE /users/:id`
/// answers 204, and both were documented as 200 with nothing to say so.
final class Success {
  const Success({
    this.status = 200,
    this.schema,
    this.contentType = 'application/json',
  }) : assert(status >= 200 && status < 400, 'a success is a 2xx or a 3xx');

  /// The status this route answers with — 201 for a create, 204 for a delete.
  final int status;

  /// The body's schema, or null when there is no body to document: a 204, or a
  /// `text/plain` liveness probe. Saying nothing is not a lie; a JSON schema
  /// over a text body would be one.
  final Schema? schema;

  /// The media type of [schema], projected as-is. Mirrors
  /// [RouteDoc.requestBodyType].
  final String contentType;
}

/// Per-route documentation, passed to a route as its opaque `doc` and read back
/// here when emitting OpenAPI.
class RouteDoc {
  const RouteDoc({
    required this.success,
    this.requestBody,
    this.requestBodyType = 'application/json',
    this.summary,
    this.failureResponses,
    this.security,
    this.query,
  });

  /// What this route answers with when it succeeds. Required: there is nowhere
  /// to write a contract without one, so a document with no 2xx is
  /// unrepresentable rather than caught after the fact.
  final Success success;

  /// The schema of the request body.
  final Schema? requestBody;

  /// The media type of [requestBody], projected as-is onto OpenAPI's
  /// `requestBody.content`. Defaults to `application/json`; set
  /// `multipart/form-data` for an upload so the contract tells the truth about
  /// what the route consumes.
  final String requestBodyType;

  final String? summary;

  /// The statuses this route fails with. The name is the constraint: a success
  /// lives in [success], and a route has exactly one. A 2xx here is rejected
  /// when the document is emitted, naming the route.
  final Map<int, Schema>? failureResponses;

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
    ?success.schema,
    ?requestBody,
    ...?failureResponses?.values,
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
