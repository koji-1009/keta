library;

import 'package:keta/keta.dart';

import 'yaml.dart';

/// An OpenAPI 3.1 document assembled from a route table. Truth flows one way:
/// the running routes and their [RouteDoc]s are the source, this document the
/// shadow.
class OpenApi {
  const OpenApi._(this.document);

  /// Walks [routes], extracting paths and parameters mechanically from the
  /// route values and bodies/responses from each route's [RouteDoc], and
  /// collecting referenced schemas transitively into `components/schemas`.
  ///
  /// [override] is the single escape hatch: it receives and may rewrite the
  /// finished document.
  factory OpenApi.fromRoutes(
    List<RouteEntry> routes, {
    String title = 'API',
    String version = '0.1.0',
    List<SecurityScheme> security = const [],
    Map<String, Object?> Function(Map<String, Object?> document)? override,
  }) {
    final paths = <String, Map<String, Object?>>{};
    final schemas = <String, Map<String, Object?>>{};
    final schemasSeen = <String, Schema>{};
    final schemaFirstRoute = <String, String>{};
    final schemasVisited = <Schema>{};
    final securitySchemes = <String, Map<String, Object?>>{};
    final routeConflicts = <String>{};
    // operationId → the route that first claimed it, so a duplicate can name
    // both sides. `tags` accumulates every route's tags for the document's
    // top-level list, deduped and sorted at the end.
    final operationIds = <String, String>{};
    final allTags = <String>{};

    for (final route in routes) {
      final doc = route.doc;
      // null follows the global default; an empty list is explicitly public.
      final effective = doc?.security ?? security;
      final path = _openApiPath(route.segments);
      final routeLabel = '${route.method} $path';
      final pathItem = paths.putIfAbsent(path, () => {});
      final method = route.method.toLowerCase();
      // Two routes with the same method+template would otherwise overwrite
      // one another here, silently, in registration order — the document
      // would then depend on registration order despite the determinism
      // contract above. `App.compile` catches this too, but this walk can run
      // standalone (a tool/openapi.dart that never serves), so it must catch
      // it independently — and it must catch the same *shape* of conflict.
      // `path` embeds capture names (`{id}` vs `{userId}`), so two routes
      // differing only in capture name would land in two different `paths`
      // entries here and slip past a `path`-keyed guard, yet `App.compile`
      // deliberately treats them as one conflict (`conflictKey` collapses
      // every capture to `*`). The guard therefore keys off that same
      // collapsed shape, not off `path`.
      final conflict = conflictKey(route.method, route.segments);
      if (!routeConflicts.add(conflict)) {
        throw StateError('route conflict: $routeLabel registered twice');
      }
      if (doc != null) {
        // Document-wide operationId uniqueness. Two operations sharing an id is
        // an invalid OpenAPI document (tooling keys code generation off it), so
        // it is a hard error naming both routes — the same collision posture the
        // schema and security-scheme guards take, not a last-wins.
        final id = doc.operationId;
        if (id != null) {
          final first = operationIds[id];
          if (first != null) {
            throw StateError(
              'operationId "$id" is declared twice — first at $first, '
              'again at $routeLabel',
            );
          }
          operationIds[id] = routeLabel;
        }
        allTags.addAll(doc.tags ?? const []);
      }
      pathItem[method] = _operation(route, doc, effective);
      if (doc != null) {
        for (final schema in doc.schemas) {
          _collect(
            schema,
            schemas,
            schemasSeen,
            schemaFirstRoute,
            routeLabel,
            schemasVisited,
          );
        }
      }
      for (final scheme in effective) {
        final existing = securitySchemes[scheme.name];
        // Last-wins would corrupt the document exactly as a schema collision
        // would: two routes naming the same security scheme differently is an
        // authoring mistake, not a thing to silently resolve by order.
        if (existing != null && !_deepEquals(existing, scheme.json)) {
          throw StateError(
            'security scheme "${scheme.name}" is declared with two different '
            'definitions — seen again at $routeLabel',
          );
        }
        securitySchemes[scheme.name] = scheme.json;
      }
    }

    // Every generated map is emitted in sorted key order, so the document is a
    // function of the route set alone and not of registration order: two apps
    // with the same routes emit the same bytes (the file-convention example and
    // the register-based one, M5's "identical output").
    final components = <String, Object?>{
      if (schemas.isNotEmpty) 'schemas': _sortedByKey(schemas),
      if (securitySchemes.isNotEmpty)
        'securitySchemes': _sortedByKey(securitySchemes),
    };
    final document = <String, Object?>{
      'openapi': '3.1.0',
      'info': {'title': title, 'version': version},
      'paths': {
        for (final path in paths.keys.toList()..sort())
          path: _sortedByKey(paths[path]!),
      },
      // Sorted and deduped so the top-level list is a function of the route set
      // alone, like every other generated collection above.
      if (allTags.isNotEmpty)
        'tags': [
          for (final tag in allTags.toList()..sort()) {'name': tag},
        ],
      if (components.isNotEmpty) 'components': components,
    };
    return OpenApi._(override == null ? document : override(document));
  }
  final Map<String, Object?> document;

  Map<String, Object?> toJson() => document;

  String toYaml() => encodeYaml(document);
}

Map<String, Object?> _operation(
  RouteEntry route,
  RouteDoc? doc,
  List<SecurityScheme> security,
) {
  final parameters = [
    for (final param in _pathParameters(route.segments))
      {'name': param.$1, 'in': 'path', 'required': true, 'schema': param.$2},
    if (doc?.query != null)
      for (final q in doc!.query!)
        {
          'name': q.name,
          'in': 'query',
          'required': q.required,
          // The capture's schema fragment projects as-is (data, not inference).
          'schema': q.capture.schema,
        },
  ];
  // OpenAPI identifies a parameter by (name, in); a collision within one
  // location (two path `p0`, or two query `tag`) is an invalid document. Fail
  // fast instead.
  final seenNames = <String>{};
  for (final param in parameters) {
    if (!seenNames.add('${param['in']}:${param['name']}')) {
      throw StateError(
        'duplicate ${param['in']} parameter "${param['name']}" in '
        '${_openApiPath(route.segments)}',
      );
    }
  }
  final responses = <String, Object?>{};
  if (doc != null) {
    final upgrade = doc.upgrade;
    final success = doc.success;
    if (upgrade != null) {
      // An upgrade route's terminal response is 101 Switching Protocols, not a
      // 2xx. It is modelled separately (see [SwitchingProtocols]) precisely
      // because a [Success] cannot hold it; here that separate declaration is
      // projected as a `101` entry. The switched protocol itself has no OpenAPI
      // body slot, so the shadow documents the switch and — when pinned — the
      // negotiated subprotocol via the standard handshake response header.
      responses['101'] = {
        'description': upgrade.description,
        if (upgrade.subprotocol != null)
          'headers': {
            'Sec-WebSocket-Protocol': {
              'description': 'The negotiated WebSocket subprotocol.',
              // `enum` (a single-member set), not `const`: keta forbids
              // authors from writing `const` (it is in the unenforced-keyword
              // rejection set), so keta's own emitter must not write it either.
              // A one-element `enum` expresses the same "exactly this value"
              // intent and is a keyword keta enforces.
              'schema': {
                'type': 'string',
                'enum': [upgrade.subprotocol],
              },
            },
          },
      };
    } else if (success != null) {
      // Success.status is only an `assert` in its constructor, so a non-const
      // `Success(status: 500)` sails through with asserts off (release builds).
      // failureResponses gets a hard StateError for the mirror mistake below;
      // the same invariant is enforced here too, so the two are not asymmetric.
      if (success.status < 200 || success.status >= 400) {
        throw StateError(
          '${route.method} ${_openApiPath(route.segments)}: '
          'Success.status is ${success.status}, which is not a 2xx/3xx — '
          'a success is always 2xx or 3xx',
        );
      }
      // Mirrors Success's own constructor `assert` for the same reason the
      // status-range check above mirrors it: `assert` is off in release builds,
      // so a non-const `Success(status: 204, schema: notNull)` — bodyless per
      // RFC 9110, yet paired with a schema here — would otherwise sail through
      // and the emitted document would document a body on a response that never
      // carries one.
      if (success.schema != null &&
          (success.status == 204 || success.status == 304)) {
        throw StateError(
          '${route.method} ${_openApiPath(route.segments)}: '
          'Success(status: ${success.status}, schema: ...) declares a body '
          'on a bodyless status — 204 and 304 must not carry a schema',
        );
      }
      // The success is not conditional: the primary [RouteDoc] requires it, so
      // there is no branch here that could leave a non-upgrade document without
      // a 2xx, and no guess about which one it is.
      responses['${success.status}'] = {
        'description': _reasonPhrase(success.status),
        if (success.schema != null)
          ..._body(success.schema!, success.contentType),
      };
    } else {
      // Neither a success nor an upgrade: unreachable through RouteDoc's
      // constructors (each sets exactly one), but held here as a hard error to
      // match the package's posture — an invalid doc never reaches a document.
      throw StateError(
        '${route.method} ${_openApiPath(route.segments)}: '
        'RouteDoc has neither a success nor an upgrade declaration',
      );
    }
    final failures = doc.failureResponses;
    if (failures != null) {
      for (final entry in failures.entries) {
        // The field name says non-2xx; the type cannot hold it to that, so it
        // is held here, where the route can be named.
        if (entry.key >= 200 && entry.key < 400) {
          throw StateError(
            '${route.method} ${_openApiPath(route.segments)}: '
            'failureResponses carries ${entry.key}, which is a success — '
            'a route has exactly one, and it belongs in RouteDoc.success',
          );
        }
        // Same treatment for anything outside 400-599: a 100, a 999, or any
        // other non-HTTP-failure key would otherwise reach an invalid document
        // unchallenged.
        if (entry.key < 400 || entry.key > 599) {
          throw StateError(
            '${route.method} ${_openApiPath(route.segments)}: '
            'failureResponses carries ${entry.key}, which is not a valid '
            'HTTP failure status — it must be 400-599',
          );
        }
        // A value is either a bare Schema (application/json, the common case)
        // or a Failure that names its own media type. `Map<int, Object>` cannot
        // hold the value to that union, so it is held here — where the route can
        // be named — matching the fail-fast treatment the range checks above
        // give a bad key.
        final value = entry.value;
        final Schema schema;
        final String contentType;
        if (value is Schema) {
          schema = value;
          contentType = 'application/json';
        } else if (value is Failure) {
          schema = value.schema;
          contentType = value.contentType;
        } else {
          throw StateError(
            '${route.method} ${_openApiPath(route.segments)}: '
            'failureResponses[${entry.key}] is a ${value.runtimeType} — '
            'a failure body must be a Schema or a Failure',
          );
        }
        responses['${entry.key}'] = {
          'description': _reasonPhrase(entry.key),
          ..._body(schema, contentType),
        };
      }
    }
  } else {
    // A route carrying no RouteDoc declares no contract at all. It still
    // answers something, and 200 is the only thing there is to say.
    responses['200'] = {'description': _reasonPhrase(200)};
  }
  // A secured operation gains a 401 automatically — a deterministic projection
  // of the declaration — unless the user documented 401 themselves (theirs wins).
  if (security.isNotEmpty && !responses.containsKey('401')) {
    responses['401'] = {'description': _reasonPhrase(401)};
  }
  return {
    if (doc?.operationId != null) 'operationId': doc!.operationId,
    if (doc?.summary != null) 'summary': doc!.summary,
    if (doc?.description != null) 'description': doc!.description,
    // Projected as-is (data, not inference); the author's declared order is
    // preserved. Document-wide aggregation into top-level `tags` is sorted and
    // deduped in `fromRoutes`.
    if (doc?.tags != null) 'tags': doc!.tags,
    if (parameters.isNotEmpty) 'parameters': parameters,
    if (doc?.requestBody != null)
      'requestBody': {
        'required': true,
        ..._body(doc!.requestBody!, doc.requestBodyType),
      },
    if (security.isNotEmpty)
      'security': [
        for (final scheme in security) {scheme.name: <String>[]},
      ],
    'responses': responses,
  };
}

/// [map] re-emitted in sorted key order, so generated output is deterministic.
Map<String, T> _sortedByKey<T>(Map<String, T> map) => {
  for (final key in map.keys.toList()..sort()) key: map[key] as T,
};

/// A `content` body under [mediaType], referencing [schema]. Every body —
/// request, success, or failure — honors its own declared media type: a request
/// body (e.g. `multipart/form-data` for an upload), a [Success.contentType], and
/// a [Failure.contentType] (e.g. `application/problem+json`) each document what
/// is truly on the wire. A bare [Schema] failure still means `application/json`,
/// the common case, but that default now lives at the call site, not here.
Map<String, Object?> _body(Schema schema, String mediaType) => {
  'content': {
    mediaType: {
      'schema': {r'$ref': '#/components/schemas/${schema.name}'},
    },
  },
};

/// The RFC 9110 (and companion RFC) reason phrase for [status], or an honest
/// `'Status <code>'` for a code with no registered name. Used for every
/// generated response `description` — success, failure, the fabricated 200, and
/// the automatic 401 — so the description is a deterministic projection of the
/// status, not a fixed `'OK'`/`''` that lied for a 201, 204, 302, or any 4xx.
/// Only codes keta can actually emit (2xx/3xx successes, 4xx/5xx failures) need
/// appear; 101 is described by [SwitchingProtocols], not from this table.
String _reasonPhrase(int status) => _reasonPhrases[status] ?? 'Status $status';

const _reasonPhrases = <int, String>{
  200: 'OK',
  201: 'Created',
  202: 'Accepted',
  203: 'Non-Authoritative Information',
  204: 'No Content',
  205: 'Reset Content',
  206: 'Partial Content',
  300: 'Multiple Choices',
  301: 'Moved Permanently',
  302: 'Found',
  303: 'See Other',
  304: 'Not Modified',
  307: 'Temporary Redirect',
  308: 'Permanent Redirect',
  400: 'Bad Request',
  401: 'Unauthorized',
  402: 'Payment Required',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  406: 'Not Acceptable',
  407: 'Proxy Authentication Required',
  408: 'Request Timeout',
  409: 'Conflict',
  410: 'Gone',
  411: 'Length Required',
  412: 'Precondition Failed',
  413: 'Content Too Large',
  414: 'URI Too Long',
  415: 'Unsupported Media Type',
  416: 'Range Not Satisfiable',
  417: 'Expectation Failed',
  421: 'Misdirected Request',
  422: 'Unprocessable Content',
  426: 'Upgrade Required',
  428: 'Precondition Required',
  429: 'Too Many Requests',
  431: 'Request Header Fields Too Large',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
  504: 'Gateway Timeout',
  505: 'HTTP Version Not Supported',
};

Iterable<(String, Map<String, Object?>)> _pathParameters(
  List<Segment> segments,
) sync* {
  var index = 0;
  for (final segment in segments) {
    if (segment is CaptureSegment) {
      yield (segment.capture.name ?? 'p$index', segment.capture.schema);
      index++;
    }
  }
}

String _openApiPath(List<Segment> segments) {
  if (segments.isEmpty) return '/';
  final buffer = StringBuffer();
  var index = 0;
  for (final segment in segments) {
    buffer.write('/');
    switch (segment) {
      case LiteralSegment(:final value):
        buffer.write(value);
      case CaptureSegment(:final capture):
        buffer.write('{${capture.name ?? 'p$index'}}');
        index++;
    }
  }
  return buffer.toString();
}

/// Collects [schema] and its transitive [Schema.deps] into [into], keyed by
/// name. The same schema legitimately reaches this walk many times (every
/// route that references it), so a name already seen is fine — as long as it
/// is the *same* schema. Two distinct definitions sharing a name would
/// first-win silently and corrupt every `$ref` pointed at that name; that is
/// caught here instead, naming the schema and (when known) the routes on both
/// sides of the collision.
///
/// **Invariant**: this always recurses into `schema.deps`, even when
/// `schema` itself just deduped against something already `seen` under its
/// name. `_sameSchema` only compares deps by *name*, not by definition (see
/// its doc), so a wrapper that reads as "the same" at this level can still
/// carry a genuinely different dependency one level down — that must not go
/// unchecked. The one thing this skips is re-walking a dep *instance*
/// (`visited` is an identity set — `Schema` has no custom `==`/`hashCode`)
/// this call tree has already fully expanded: the legitimate case of many
/// routes sharing one `const` dep. Recursion always terminates because a
/// `const Schema` graph is acyclic — const construction cannot reference an
/// enclosing, not-yet-built const value, so there is no cycle to loop on.
void _collect(
  Schema schema,
  Map<String, Map<String, Object?>> into,
  Map<String, Schema> seen,
  Map<String, String> firstRoute,
  String? routeLabel,
  Set<Schema> visited,
) {
  final existing = seen[schema.name];
  if (existing == null) {
    seen[schema.name] = schema;
    if (routeLabel != null) firstRoute[schema.name] = routeLabel;
    into[schema.name] = schema.json;
  } else if (!_sameSchema(existing, schema)) {
    final firstLabel = firstRoute[schema.name];
    final seenAt = firstLabel != null && routeLabel != null
        ? ' — first collected at $firstLabel, again at $routeLabel'
        : '';
    throw StateError(
      'schema "${schema.name}" is registered with two different '
      'definitions$seenAt; a \$ref target must be unambiguous',
    );
  }
  if (!visited.add(schema)) return;
  for (final dep in schema.deps) {
    _collect(dep, into, seen, firstRoute, routeLabel, visited);
  }
}

/// Whether [a] and [b] are the same schema for collision purposes: the same
/// instance (the common case — one `const Schema` referenced from many
/// routes), or, failing that, equal content (json and the set of dep names).
///
/// Comparing deps by name only — not by their full definition — is
/// deliberate and only safe because `_collect` (see its invariant) always
/// recurses into `schema.deps` regardless of this function's verdict: a dep
/// that shares a name but differs in substance gets its own full check one
/// call deeper, where it is named directly. This function decides only
/// whether [schema] itself is worth registering under its name; it is never
/// the last word on the subtree beneath it.
bool _sameSchema(Schema a, Schema b) {
  if (identical(a, b)) return true;
  if (!_deepEquals(a.json, b.json)) return false;
  final aDeps = a.deps.map((d) => d.name).toSet();
  final bDeps = b.deps.map((d) => d.name).toSet();
  return aDeps.length == bDeps.length && aDeps.containsAll(bDeps);
}

/// Structural equality over JSON-shaped values (the only values a schema or
/// security-scheme fragment ever carries), used to tell a genuine name/scheme
/// collision from the same fragment reaching the collector more than once.
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
