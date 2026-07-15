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
    final securitySchemes = <String, Map<String, Object?>>{};

    for (final route in routes) {
      final doc = route.doc is RouteDoc ? route.doc as RouteDoc : null;
      // null follows the global default; an empty list is explicitly public.
      final effective = doc?.security ?? security;
      final pathItem = paths.putIfAbsent(
        _openApiPath(route.segments),
        () => {},
      );
      pathItem[route.method.toLowerCase()] = _operation(route, doc, effective);
      if (doc != null) {
        for (final schema in doc.schemas) {
          _collect(schema, schemas);
        }
      }
      for (final scheme in effective) {
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
  if (doc?.response != null) {
    responses['200'] = {'description': 'OK', ..._jsonBody(doc!.response!)};
  }
  if (doc?.responses != null) {
    for (final entry in doc!.responses!.entries) {
      responses['${entry.key}'] = {
        'description': '',
        ..._jsonBody(entry.value),
      };
    }
  }
  final documentedAny = responses.isNotEmpty;
  // A secured operation gains a 401 automatically — a deterministic projection
  // of the declaration — unless the user documented 401 themselves (theirs wins).
  if (security.isNotEmpty && !responses.containsKey('401')) {
    responses['401'] = {'description': 'Unauthorized'};
  }
  // Only fabricate a 200 when the route documents no response at all.
  if (!documentedAny) {
    responses['200'] = {'description': 'OK'};
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

void _collect(Schema schema, Map<String, Map<String, Object?>> into) {
  if (into.containsKey(schema.name)) return;
  into[schema.name] = schema.json;
  for (final dep in schema.deps) {
    _collect(dep, into);
  }
}
