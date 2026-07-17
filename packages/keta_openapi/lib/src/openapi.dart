library;

import 'package:keta/keta.dart';

import 'route_doc.dart';
import 'schema.dart';
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
    final securitySchemes = <String, Map<String, Object?>>{};

    for (final route in routes) {
      final doc = route.doc is RouteDoc ? route.doc as RouteDoc : null;
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
      // it independently.
      if (pathItem.containsKey(method)) {
        throw StateError('route conflict: $routeLabel registered twice');
      }
      pathItem[method] = _operation(route, doc, effective);
      if (doc != null) {
        for (final schema in doc.schemas) {
          _collect(schema, schemas, schemasSeen, schemaFirstRoute, routeLabel);
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
    // Success.status is only an `assert` in its constructor, so a non-const
    // `Success(status: 500)` sails through with asserts off (release builds).
    // failureResponses gets a hard StateError for the mirror mistake below; the
    // same invariant is enforced here too, so the two are no longer asymmetric.
    if (doc.success.status < 200 || doc.success.status >= 400) {
      throw StateError(
        '${route.method} ${_openApiPath(route.segments)}: '
        'Success.status is ${doc.success.status}, which is not a 2xx/3xx — '
        'a success is always 2xx or 3xx',
      );
    }
    // The success is not conditional: [RouteDoc.success] is required, so there
    // is no branch here that could leave a document without a 2xx, and no guess
    // about which one it is.
    responses['${doc.success.status}'] = {
      'description': 'OK',
      if (doc.success.schema != null)
        ..._body(doc.success.schema!, doc.success.contentType),
    };
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
        responses['${entry.key}'] = {
          'description': '',
          ..._jsonBody(entry.value),
        };
      }
    }
  } else {
    // A route carrying no RouteDoc declares no contract at all. It still
    // answers something, and 200 is the only thing there is to say.
    responses['200'] = {'description': 'OK'};
  }
  // A secured operation gains a 401 automatically — a deterministic projection
  // of the declaration — unless the user documented 401 themselves (theirs wins).
  if (security.isNotEmpty && !responses.containsKey('401')) {
    responses['401'] = {'description': 'Unauthorized'};
  }
  return {
    if (doc?.summary != null) 'summary': doc!.summary,
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

/// A `content` body under [mediaType], referencing [schema]. Responses always
/// use `application/json`; a request body honors its declared media type (e.g.
/// `multipart/form-data`), so an upload is documented as what it truly consumes.
Map<String, Object?> _body(Schema schema, String mediaType) => {
  'content': {
    mediaType: {
      'schema': {r'$ref': '#/components/schemas/${schema.name}'},
    },
  },
};

Map<String, Object?> _jsonBody(Schema schema) =>
    _body(schema, 'application/json');

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
void _collect(
  Schema schema,
  Map<String, Map<String, Object?>> into,
  Map<String, Schema> seen,
  Map<String, String> firstRoute,
  String? routeLabel,
) {
  final existing = seen[schema.name];
  if (existing != null) {
    if (_sameSchema(existing, schema)) return;
    final firstLabel = firstRoute[schema.name];
    final seenAt = firstLabel != null && routeLabel != null
        ? ' — first collected at $firstLabel, again at $routeLabel'
        : '';
    throw StateError(
      'schema "${schema.name}" is registered with two different '
      'definitions$seenAt; a \$ref target must be unambiguous',
    );
  }
  seen[schema.name] = schema;
  if (routeLabel != null) firstRoute[schema.name] = routeLabel;
  into[schema.name] = schema.json;
  for (final dep in schema.deps) {
    _collect(dep, into, seen, firstRoute, routeLabel);
  }
}

/// Whether [a] and [b] are the same schema for collision purposes: the same
/// instance (the common case — one `const Schema` referenced from many
/// routes), or, failing that, equal content (json and the set of dep names).
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
