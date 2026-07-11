library;

import 'package:keta/keta.dart';

import 'route_doc.dart';
import 'schema.dart';
import 'yaml.dart';

/// An OpenAPI 3.1 document assembled from a route table. Truth flows one way:
/// the running routes and their [RouteDoc]s are the source, this document the
/// shadow.
class OpenApi {
  final Map<String, Object?> document;

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
    Map<String, Object?> Function(Map<String, Object?> document)? override,
  }) {
    final paths = <String, Map<String, Object?>>{};
    final schemas = <String, Map<String, Object?>>{};

    for (final route in routes) {
      final doc = route.doc is RouteDoc ? route.doc as RouteDoc : null;
      final pathItem = paths.putIfAbsent(_openApiPath(route.segments), () => {});
      pathItem[route.method.toLowerCase()] = _operation(route, doc);
      if (doc != null) {
        for (final schema in doc.schemas) {
          _collect(schema, schemas);
        }
      }
    }

    final document = <String, Object?>{
      'openapi': '3.1.0',
      'info': {'title': title, 'version': version},
      'paths': paths,
      if (schemas.isNotEmpty) 'components': {'schemas': schemas},
    };
    return OpenApi._(override == null ? document : override(document));
  }

  Map<String, Object?> toJson() => document;

  String toYaml() => encodeYaml(document);
}

Map<String, Object?> _operation(RouteEntry route, RouteDoc? doc) {
  final parameters = [
    for (final param in _pathParameters(route.segments))
      {
        'name': param.$1,
        'in': 'path',
        'required': true,
        'schema': {'type': param.$2},
      },
  ];
  final responses = <String, Object?>{
    '200': {
      'description': 'OK',
      if (doc?.response != null) ..._jsonBody(doc!.response!),
    },
  };
  if (doc?.responses != null) {
    for (final entry in doc!.responses!.entries) {
      responses['${entry.key}'] = {
        'description': '',
        ..._jsonBody(entry.value),
      };
    }
  }
  return {
    if (doc?.summary != null) 'summary': doc!.summary,
    if (parameters.isNotEmpty) 'parameters': parameters,
    if (doc?.requestBody != null)
      'requestBody': {
        'required': true,
        ..._jsonBody(doc!.requestBody!),
      },
    'responses': responses,
  };
}

Map<String, Object?> _jsonBody(Schema schema) => {
      'content': {
        'application/json': {
          'schema': {r'$ref': '#/components/schemas/${schema.name}'},
        },
      },
    };

Iterable<(String, String)> _pathParameters(List<Segment> segments) sync* {
  var index = 0;
  for (final segment in segments) {
    if (segment is CaptureSegment) {
      yield (segment.capture.name ?? 'p$index', segment.capture.schemaType);
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
