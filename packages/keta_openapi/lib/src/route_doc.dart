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

/// A failure response that carries a non-JSON body. Mirrors [Success] on the
/// error side: a [Success] declares its `contentType`, but a bare [Schema] in
/// [RouteDoc.failureResponses] could only ever mean `application/json` — an
/// asymmetry that made a `text/plain` or `application/problem+json` error
/// unrepresentable. Wrap the schema in a [Failure] to say what the error body
/// truly is.
///
/// [RouteDoc.failureResponses] therefore accepts `Object` values: a bare
/// [Schema] (the common case, still `application/json`) OR a [Failure]. The
/// emitter type-checks each value and rejects anything else as a hard error
/// naming the route — the same fail-fast posture the range and 2xx checks take,
/// rather than a compile-time `Map<int, Schema | Failure>` the language cannot
/// express.
final class Failure {
  const Failure(this.schema, {this.contentType = 'application/json'});

  /// The error body's schema.
  final Schema schema;

  /// The media type of [schema], projected as-is onto the response's
  /// `content`. Mirrors [Success.contentType].
  final String contentType;
}

/// Per-route documentation, passed to a route as its opaque `doc` and read back
/// here when emitting OpenAPI.
class RouteDoc {
  const RouteDoc({
    required Success this.success,
    this.requestBody,
    this.requestBodyType = 'application/json',
    this.summary,
    this.description,
    this.tags,
    this.operationId,
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
    this.description,
    this.tags,
    this.operationId,
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

  /// A longer, human-readable prose description of the operation, projected onto
  /// the operation's `description`. Complements the one-line [summary]. Optional:
  /// absent means the operation carries no `description`.
  final String? description;

  /// Free-form tags for grouping this operation, projected onto the operation's
  /// `tags` and aggregated (sorted and deduped) into the document's top-level
  /// `tags` list so the whole document stays a deterministic function of the
  /// route set. Optional.
  final List<String>? tags;

  /// A document-wide-unique identifier for this operation, projected onto the
  /// operation's `operationId`. Uniqueness is enforced when the document is
  /// emitted: two routes declaring the same [operationId] are a hard error
  /// naming both, matching the package's collision posture for schemas and
  /// security schemes. Optional.
  final String? operationId;

  /// The statuses this route fails with. The name is the constraint: a success
  /// lives in [success], and a route has exactly one. A 2xx here is rejected
  /// when the document is emitted, naming the route.
  ///
  /// A value is either a bare [Schema] (an `application/json` body, the common
  /// case) or a [Failure] (a body under any declared media type). The type is
  /// `Object` because the language cannot spell `Schema | Failure`; the emitter
  /// checks each value and rejects anything else as a hard error naming the
  /// route.
  final Map<int, Object>? failureResponses;

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
  ///
  /// A [failureResponses] value is unwrapped to its [Schema] whether it is a
  /// bare schema or a [Failure]. An unrecognized value is not surfaced here (it
  /// carries no schema to collect); the emitter rejects it as a hard error, with
  /// the route name in hand, before this collection would matter.
  Iterable<Schema> get schemas => [
    ?success?.schema,
    ?requestBody,
    if (failureResponses != null)
      for (final value in failureResponses!.values)
        if (value is Schema)
          value
        else if (value is Failure)
          value.schema,
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
