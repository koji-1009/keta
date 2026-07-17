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
  }) : assert(status >= 200 && status < 400, 'a success is a 2xx or a 3xx'),
       assert(
         schema == null || (status != 204 && status != 304),
         'a 204 or 304 has no body — schema must be null',
       );

  /// The status this route answers with — 201 for a create, 204 for a delete.
  final int status;

  /// The body's schema, or null when there is no body to document: a 204, or a
  /// `text/plain` liveness probe. Saying nothing is not a lie; a JSON schema
  /// over a text body would be one.
  ///
  /// 204 and 304 are bodyless by definition (RFC 9110 §15.3.5, §15.4.5) — a
  /// [schema] paired with either is a contract lie the emitter would have
  /// happily written down: "the body looks like this" over a response that
  /// carries no body at all. The constructor's `assert` catches it in debug
  /// builds; [OpenApi.fromRoutes] repeats the check as a hard error (asserts
  /// are off in release builds) so the lie can never reach a shipped document.
  final Schema? schema;

  /// The media type of [schema], projected as-is. Mirrors
  /// [RouteDoc.requestBodyType].
  final String contentType;
}

/// What an upgrade route answers with: 101 Switching Protocols, then another
/// protocol entirely. It sits parallel to [Success] — the note's "Success と
/// 同列の宣言(値)" — precisely because it cannot BE a [Success]: a [Success]
/// asserts a 2xx/3xx, and a 101 is neither. A 101 does not mean "the request
/// succeeded, here is the body"; it means "this connection is leaving HTTP." The
/// two are different kinds of answer, so they are different types, and a route
/// declares exactly one of them.
///
/// OpenAPI has no first-class representation of the switched protocol (a
/// WebSocket session is not an HTTP response body), so the shadow documents the
/// switch itself: a `101` response entry, plus the negotiated [subprotocol] when
/// the route pins one.
final class SwitchingProtocols {
  const SwitchingProtocols({
    this.subprotocol,
    this.description = 'Switching Protocols',
  });

  /// The WebSocket subprotocol this endpoint negotiates, or null when it pins
  /// none. Projected onto the `101` entry's `Sec-WebSocket-Protocol` header so
  /// the contract names what the connection will speak.
  final String? subprotocol;

  /// The human-readable description of the `101` response.
  final String description;
}

/// Per-route documentation, passed to a route as its opaque `doc` and read back
/// here when emitting OpenAPI.
class RouteDoc {
  const RouteDoc({
    required Success this.success,
    this.requestBody,
    this.requestBodyType = 'application/json',
    this.summary,
    this.failureResponses,
    this.security,
    this.query,
  }) : upgrade = null;

  /// The doc for a route that answers by switching protocols (a WebSocket
  /// upgrade). It carries a [SwitchingProtocols] instead of a [success] — the
  /// 101 IS its terminal response — while everything else composes unchanged:
  /// [failureResponses] (a 426 or 401), [security] (still adds the automatic
  /// 401), and [query]. Kept a distinct constructor rather than a nullable
  /// [success] so the ordinary `RouteDoc(success: ...)` stays non-null and every
  /// existing caller is untouched.
  const RouteDoc.upgrade({
    required SwitchingProtocols this.upgrade,
    this.requestBody,
    this.requestBodyType = 'application/json',
    this.summary,
    this.failureResponses,
    this.security,
    this.query,
  }) : success = null;

  /// What this route answers with when it succeeds, or null for an upgrade route
  /// (which answers 101 — see [upgrade]). Non-null for every route built with
  /// the primary constructor: an ordinary contract with no 2xx is
  /// unrepresentable rather than caught after the fact.
  final Success? success;

  /// Non-null for an upgrade route (built with [RouteDoc.upgrade]): its 101
  /// declaration, mutually exclusive with [success].
  final SwitchingProtocols? upgrade;

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

  /// Every schema this doc references, for transitive component collection. An
  /// upgrade route has no [success] schema (its 101 carries no body), so that
  /// slot is simply absent.
  Iterable<Schema> get schemas => [
    ?success?.schema,
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
