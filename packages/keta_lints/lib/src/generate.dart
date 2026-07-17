library;

import 'dart_literal.dart';

/// The files a scaffold run produces, all user-owned Dart source.
class Scaffold {
  const Scaffold({
    required this.dtos,
    required this.routes,
    required this.openapiTool,
    required this.contractTest,
  });
  final String dtos;
  final String routes;
  final String openapiTool;
  final String contractTest;
}

/// Materializes canonical Dart from an OpenAPI 3.1 [document]: DTOs with
/// fromJson/toJson, Schema constants, typed route skeletons that throw 501, a
/// tool/openapi.dart, and DTO-level contract tests. The mapping is unique over
/// the canonical subset; out-of-scope constructs raise [ScaffoldError].
Scaffold generateScaffold(Map<String, Object?> document) {
  final schemas = _namedSchemas(document);
  _checkSchemaNames(schemas);
  _checkRefCycles(schemas);
  final dtos = _generateDtos(schemas);
  final routes = _generateRoutes(document, schemas);
  return Scaffold(
    dtos: dtos,
    routes: routes,
    openapiTool: _openapiTool,
    contractTest: _generateContractTest(document, schemas),
  );
}

/// Raised when a schema uses a construct outside the canonical subset.
class ScaffoldError implements Exception {
  const ScaffoldError(this.message);
  final String message;
  @override
  String toString() => 'ScaffoldError: $message';
}

Map<String, Map<String, Object?>> _namedSchemas(Map<String, Object?> document) {
  final components = document['components'];
  final schemas = components is Map ? components['schemas'] : null;
  if (schemas is! Map) return {};
  return {
    for (final entry in schemas.entries)
      entry.key.toString(): _asSchemaObject(entry.value, entry.key.toString()),
  };
}

/// Validates that a schema-shaped [value] from the oracle document is
/// actually an object, naming the offending schema/property in the error
/// instead of letting a bare cast crash with a raw TypeError — the oracle is
/// external input and every rejection must be a descriptive [ScaffoldError].
Map<String, Object?> _asSchemaObject(Object? value, String name) {
  if (value is! Map) {
    throw ScaffoldError('schema "$name" is not an object schema: $value');
  }
  return value.cast<String, Object?>();
}

/// Validates a schema's `required` list, when present, is a list of strings.
List<String> _requiredOf(Map<String, Object?> schema, String name) {
  final required = schema['required'];
  if (required == null) return const [];
  if (required is! List || required.any((e) => e is! String)) {
    throw ScaffoldError(
      'schema "$name" has a non-string-list "required": $required',
    );
  }
  return required.cast<String>();
}

/// Validates a schema's `properties` map, when present, is an object.
Map<String, Object?> _propertiesOf(Map<String, Object?> schema, String name) {
  final properties = schema['properties'];
  if (properties == null) return const {};
  if (properties is! Map) {
    throw ScaffoldError(
      'schema "$name" has a non-object "properties": $properties',
    );
  }
  return properties.cast<String, Object?>();
}

bool _isEnum(Map<String, Object?> schema) =>
    schema['type'] == 'string' && schema['enum'] is List;

// --- DTOs -----------------------------------------------------------------

String _generateDtos(Map<String, Map<String, Object?>> schemas) {
  final hasSealed = schemas.values.any(_isSealed);
  final buffer = StringBuffer();
  // A sealed variant's fromJson switch throws BadRequest on an unknown tag.
  if (hasSealed) buffer.writeln("import 'package:keta/keta.dart';");
  buffer
    ..writeln("import 'package:keta_openapi/keta_openapi.dart';")
    ..writeln();
  // Each sealed type's variants carry `implements <Sealed>`, so the
  // switch-delegation is well-typed.
  final variantOf = <String, String>{};
  for (final entry in schemas.entries) {
    if (_isSealed(entry.value)) {
      for (final variant in _variants(entry.value).values) {
        variantOf[variant] = entry.key;
      }
    }
  }
  for (final entry in schemas.entries) {
    final name = entry.key;
    final schema = entry.value;
    if (_isSealed(schema)) {
      _writeSealed(buffer, name, schema);
    } else if (_isEnum(schema)) {
      _writeEnum(buffer, name, schema);
    } else if (schema['type'] == 'object') {
      _writeClass(
        buffer,
        name,
        schema,
        schemas,
        implementsType: variantOf[name],
      );
    } else {
      buffer.writeln(
        '// keta: "$name" is outside the canonical subset '
        '(materialize by hand).',
      );
    }
    _writeSchemaConstant(buffer, name, schema, schemas);
    buffer.writeln();
  }
  return buffer.toString();
}

bool _isSealed(Map<String, Object?> schema) =>
    schema['oneOf'] is List && schema['discriminator'] is Map;

/// A sealed type's discriminator tag → variant type name, from an explicit
/// `discriminator.mapping` or, absent one, the `oneOf` refs with the tag being
/// the variant's lowerCamel name.
Map<String, String> _variants(Map<String, Object?> schema) {
  final mapping = (schema['discriminator'] as Map)['mapping'];
  if (mapping is Map) {
    return {
      for (final e in mapping.entries)
        e.key.toString(): _refName(e.value.toString()),
    };
  }
  return {
    for (final ref in schema['oneOf'] as List)
      if (ref is Map && ref[r'$ref'] is String)
        _lowerFirst(_refName(ref[r'$ref'] as String)): _refName(
          ref[r'$ref'] as String,
        ),
  };
}

void _writeSealed(
  StringBuffer buffer,
  String name,
  Map<String, Object?> schema,
) {
  final discriminator = (schema['discriminator'] as Map)['propertyName']
      .toString();
  buffer
    ..writeln('sealed class $name {')
    ..writeln('  factory $name.fromJson(Map<String, Object?> json) =>')
    ..writeln('      switch (json[${dartStringLiteral(discriminator)}]) {');
  for (final entry in _variants(schema).entries) {
    buffer.writeln(
      '        ${dartStringLiteral(entry.key)} => '
      '${entry.value}.fromJson(json),',
    );
  }
  buffer
    ..writeln(
      "        _ => throw const BadRequest('unknown $name $discriminator'),",
    )
    ..writeln('      };')
    ..writeln('  Map<String, Object?> toJson();')
    ..writeln('}')
    ..writeln();
}

void _writeEnum(StringBuffer buffer, String name, Map<String, Object?> schema) {
  final raw = schema['enum'] as List;
  // Enum constants map name↔wire via `.name`/`.byName`, so each value must be a
  // string that is also a valid, non-reserved Dart identifier as-is. Reject
  // (don't emit broken code, and don't let a non-string value crash as a bare
  // TypeError — the oracle document is external input).
  for (final v in raw) {
    if (v is! String) {
      throw ScaffoldError(
        'enum "$name" has a non-string value $v; materialize this enum by '
        'hand',
      );
    }
    if (!_isValidIdentifier(v) || _reservedWords.contains(v)) {
      throw ScaffoldError(
        'enum "$name" value "$v" is not a valid Dart identifier; '
        'materialize this enum by hand',
      );
    }
  }
  final values = raw.cast<String>();
  buffer.writeln('enum $name { ${values.join(', ')} }');
  buffer.writeln();
}

void _writeClass(
  StringBuffer buffer,
  String name,
  Map<String, Object?> schema,
  Map<String, Map<String, Object?>> schemas, {
  String? implementsType,
}) {
  final required = _requiredOf(schema, name);
  final properties = _propertiesOf(schema, name);
  // JSON property names become valid, unique Dart identifiers; the original
  // wire key is kept for the fromJson/toJson maps.
  final usedNames = <String>{};
  final fields = [
    for (final entry in properties.entries)
      _Field(
        entry.key,
        _uniqueIdent(_sanitizeIdentifier(entry.key), usedNames),
        _resolve(_asSchemaObject(entry.value, '$name.${entry.key}'), schemas),
        required.contains(entry.key),
      ),
  ];

  final clause = implementsType == null ? '' : ' implements $implementsType';
  buffer.writeln('class $name$clause {');
  // Constructors first (sort_constructors_first). Every field is final with
  // initializing formals only, so the DTO is const-eligible.
  if (fields.isEmpty) {
    buffer.writeln('  const $name();');
  } else {
    buffer.writeln('  const $name({');
    for (final f in fields) {
      buffer.writeln(
        f.required
            ? '    required this.${f.dartName},'
            : '    this.${f.dartName},',
      );
    }
    buffer.writeln('  });');
  }
  buffer.writeln();

  buffer.writeln(
    '  factory $name.fromJson(Map<String, Object?> json) => $name(',
  );
  for (final f in fields) {
    buffer.writeln(
      '        ${f.dartName}: ${f.fromJson("json['${f.jsonKey}']")},',
    );
  }
  buffer.writeln('      );');
  buffer.writeln();

  for (final f in fields) {
    buffer.writeln('  final ${f.dartType} ${f.dartName};');
  }
  if (fields.isNotEmpty) buffer.writeln();

  // A sealed variant's toJson overrides the parent's abstract method.
  if (implementsType != null) buffer.writeln('  @override');
  buffer.writeln('  Map<String, Object?> toJson() => {');
  for (final f in fields) {
    buffer.writeln(f.toJsonEntry());
  }
  buffer.writeln('      };');
  buffer.writeln('}');
  buffer.writeln();
}

void _writeSchemaConstant(
  StringBuffer buffer,
  String name,
  Map<String, Object?> schema,
  Map<String, Map<String, Object?>> schemas,
) {
  final deps = _refsIn(
    schema,
  ).where((r) => r != name && schemas.containsKey(r)).toSet().toList()..sort();
  final constName = '${_lowerFirst(name)}Schema';
  buffer.write("const $constName = Schema('$name', ${dartLiteral(schema)}");
  if (deps.isNotEmpty) {
    buffer.write(
      ', deps: [${deps.map((d) => '${_lowerFirst(d)}Schema').join(', ')}]',
    );
  }
  buffer.writeln(');');
}

// --- type model -----------------------------------------------------------

sealed class _Type {
  const _Type();
}

class _Prim extends _Type {
  const _Prim(this.dart);
  final String dart;
}

class _Enum extends _Type {
  const _Enum(this.name);
  final String name;
}

class _Ref extends _Type {
  const _Ref(this.name);
  final String name;
}

class _ListOf extends _Type {
  const _ListOf(this.item);
  final _Type item;
}

_Type _resolve(
  Map<String, Object?> prop,
  Map<String, Map<String, Object?>> schemas,
) {
  final ref = prop[r'$ref'];
  if (ref is String) {
    final name = _refName(ref);
    final target = schemas[name];
    if (target != null && _isEnum(target)) return _Enum(name);
    return _Ref(name);
  }
  return switch (prop['type']) {
    'string' => const _Prim('String'),
    'integer' => const _Prim('int'),
    'number' => const _Prim('double'),
    'boolean' => const _Prim('bool'),
    'array' => _ListOf(_resolve(_itemsSchemaOf(prop), schemas)),
    _ => throw ScaffoldError('unsupported property schema: $prop'),
  };
}

/// Validates a `type: array` schema declares an object `items` schema,
/// naming the offending array schema instead of letting `items` being absent
/// or non-object crash as a bare TypeError.
Map<String, Object?> _itemsSchemaOf(Map<String, Object?> prop) {
  final items = prop['items'];
  if (items is! Map) {
    throw ScaffoldError('array schema is missing an "items" schema: $prop');
  }
  return items.cast<String, Object?>();
}

String _dartType(_Type type) => switch (type) {
  _Prim(:final dart) => dart,
  _Enum(:final name) => name,
  _Ref(:final name) => name,
  _ListOf(:final item) => 'List<${_dartType(item)}>',
};

class _Field {
  _Field(this.jsonKey, this.dartName, this.type, this.required);
  final String jsonKey;
  final String dartName;
  final _Type type;
  final bool required;

  String get dartType => required ? _dartType(type) : '${_dartType(type)}?';

  String fromJson(String access) {
    final t = type;
    // Nullable primitives (except double) read cleanly with `as T?`, matching
    // the hand-written canonical shape.
    if (!required && t is _Prim && t.dart != 'double') {
      return '$access as ${t.dart}?';
    }
    final expr = _fromJsonExpr(access, type);
    return required ? expr : '$access == null ? null : $expr';
  }

  String toJsonEntry() {
    final value = _toJsonExpr(dartName, type, nullable: !required);
    if (required) return "        '$jsonKey': $value,";
    return "        if ($dartName != null) '$jsonKey': $value,";
  }
}

String _fromJsonExpr(String access, _Type type) => switch (type) {
  _Prim(dart: 'double') => '($access as num).toDouble()',
  _Prim(:final dart) => '$access as $dart',
  _Enum(:final name) => '$name.values.byName($access as String)',
  _Ref(:final name) => '$name.fromJson($access as Map<String, Object?>)',
  _ListOf(item: _Prim(dart: 'double')) =>
    '($access as List).map((e) => (e as num).toDouble()).toList()',
  _ListOf(item: _Prim(:final dart)) => '($access as List).cast<$dart>()',
  _ListOf(item: _Enum(:final name)) =>
    '($access as List).map((e) => $name.values.byName(e as String)).toList()',
  _ListOf(item: _Ref(:final name)) =>
    '($access as List).map((e) => $name.fromJson(e as Map<String, Object?>)).toList()',
  _ListOf(:final item) => throw ScaffoldError('nested list: $item'),
};

String _toJsonExpr(String name, _Type type, {required bool nullable}) {
  final bang = nullable ? '!' : '';
  return switch (type) {
    _Prim() => name,
    _Enum() => '$name$bang.name',
    _Ref() => '$name$bang.toJson()',
    _ListOf(item: _Prim()) => name,
    _ListOf(item: _Enum()) => '$name$bang.map((e) => e.name).toList()',
    _ListOf(item: _Ref()) => '$name$bang.map((e) => e.toJson()).toList()',
    _ListOf() => name,
  };
}

// --- routes, tool, tests --------------------------------------------------

String _generateRoutes(
  Map<String, Object?> document,
  Map<String, Map<String, Object?>> schemas,
) {
  final buffer = StringBuffer()
    ..writeln("import 'package:keta/keta.dart';")
    ..writeln("import 'package:keta_openapi/keta_openapi.dart';")
    ..writeln()
    ..writeln("import 'dtos.dart';")
    ..writeln()
    ..writeln('/// Route skeletons materialized from the contract. Each throws')
    ..writeln('/// 501 until implemented; the red contract tests are the work.')
    ..writeln('void register<E>(App<E> app) {');

  final paths = (document['paths'] as Map?)?.cast<String, Object?>() ?? {};
  for (final pathEntry in paths.entries) {
    final item = (pathEntry.value as Map).cast<String, Object?>();
    for (final opEntry in item.entries) {
      final method = opEntry.key;
      if (!_httpMethods.contains(method)) continue;
      final op = (opEntry.value as Map).cast<String, Object?>();
      // Always a doc: RouteDoc.success is required, so there is no scaffolded
      // route without a declared success.
      buffer.writeln("  app.$method('${_ketaPath(pathEntry.key)}',");
      buffer.writeln(
        "      (c) => throw const NotImplementedYet('not implemented'),",
      );
      buffer.writeln('      doc: ${_routeDoc(op)},');
      buffer.writeln('  );');
    }
  }
  buffer.writeln('}');
  buffer
    ..writeln()
    ..writeln('/// The single assembly point for the app: main, the contract')
    ..writeln(
      '/// tests, and tool/openapi.dart all build it here, so middleware',
    )
    ..writeln('/// wired once below covers all three.')
    ..writeln('App<Object?> buildApp() {')
    ..writeln('  final app = App<Object?>();')
    ..writeln('  // TODO: wire middleware here -- recover(), tx(), and for the')
    ..writeln('  // declared security app.use(enforceSecurity(policy)). The')
    ..writeln(
      '  // "no credentials -> 401" contract tests stay red until you do.',
    )
    ..writeln('  register(app);')
    ..writeln('  return app;')
    ..writeln('}');
  return buffer.toString();
}

String _routeDoc(Map<String, Object?> op) {
  final parts = <String>['success: ${_successDecl(op)}'];
  final summary = op['summary'];
  if (summary is String) parts.add('summary: ${dartStringLiteral(summary)}');
  final request = _schemaRefName(((op['requestBody'] as Map?)?['content']));
  if (request != null) parts.add('requestBody: ${_lowerFirst(request)}Schema');
  final security = _securityDecl(op['security']);
  if (security != null) parts.add('security: $security');
  final query = _queryDecl(op);
  if (query != null) parts.add('query: $query');
  return 'RouteDoc(${parts.join(', ')})';
}

/// The `success:` argument, taken from the operation's own 2xx/3xx rather than
/// from the 200 slot alone: a document declaring 201 scaffolds a 201, and the
/// code does not start out contradicting the spec it was generated from. The
/// lowest success wins when several are declared; with none, 200 is the only
/// thing there is to say.
String _successDecl(Map<String, Object?> op) {
  final responses = op['responses'];
  if (responses is! Map) return 'Success()';
  final declared =
      responses.keys
          .map((key) => int.tryParse('$key'))
          .nonNulls
          .where((status) => status >= 200 && status < 400)
          .toList()
        ..sort();
  final status = declared.isEmpty ? 200 : declared.first;
  final schema = _schemaRefName((responses['$status'] as Map?)?['content']);
  final args = <String>[
    if (status != 200) 'status: $status',
    if (schema != null) 'schema: ${_lowerFirst(schema)}Schema',
  ];
  return 'Success(${args.join(', ')})';
}

/// The `query:` argument for a generated RouteDoc from the operation's
/// `in: query` parameters, or null when there are none. Each param's schema type
/// maps to a provided capture constant.
String? _queryDecl(Map<String, Object?> op) {
  final parameters = op['parameters'];
  if (parameters is! List) return null;
  final decls = <String>[];
  for (final p in parameters) {
    if (p is! Map || p['in'] != 'query') continue;
    final name = dartStringLiteral(p['name'].toString());
    final capture = _captureFor((p['schema'] as Map?)?.cast<String, Object?>());
    final required = p['required'] == true ? ', required: true' : '';
    decls.add('QueryParam($name, $capture$required)');
  }
  return decls.isEmpty ? null : '[${decls.join(', ')}]';
}

String _captureFor(Map<String, Object?>? schema) => switch (schema?['type']) {
  'string' => 'string',
  'integer' => 'integer',
  'number' => 'number',
  'boolean' => 'boolean',
  final type => throw ScaffoldError(
    'query parameter schema type "$type" is outside the canonical subset '
    '(string, integer, number, boolean)',
  ),
};

/// The `security:` argument for a generated RouteDoc, or null when the operation
/// declares none. `[]` is preserved as `const []` (explicit publicness); each
/// requirement's scheme maps to a provided constant (bearer/apiKey). A scheme
/// outside that set is outside the canonical subset.
String? _securityDecl(Object? security) {
  if (security is! List) return null;
  if (security.isEmpty) return 'const []';
  final schemes = [
    for (final req in security)
      if (req is Map && req.isNotEmpty)
        switch (req.keys.first.toString()) {
          'bearer' => 'bearer',
          'apiKey' => 'apiKey',
          final name => throw ScaffoldError(
            'security scheme "$name" is outside the provided set '
            '(bearer, apiKey); inject it via the OpenApi override hatch',
          ),
        },
  ];
  return schemes.isEmpty ? null : '[${schemes.join(', ')}]';
}

String? _schemaRefName(Object? content) {
  if (content is! Map) return null;
  final json = content['application/json'];
  final schema = json is Map ? json['schema'] : null;
  final ref = schema is Map ? schema[r'$ref'] : null;
  return ref is String ? _refName(ref) : null;
}

String _generateContractTest(
  Map<String, Object?> document,
  Map<String, Map<String, Object?>> schemas,
) {
  final secured = _securedEndpoints(document);
  final requiredQuery = _requiredQueryEndpoints(document);
  final needsApp = secured.isNotEmpty || requiredQuery.isNotEmpty;
  final buffer = StringBuffer();
  // Endpoint tests drive the app through buildApp, so they need the test client
  // and the routes; import them only when there are such tests, so the output
  // always passes analyze.
  if (needsApp) buffer.writeln("import 'package:keta/test.dart';");
  buffer.writeln("import 'package:test/test.dart';");
  buffer
    ..writeln()
    ..writeln("import '../lib/dtos.dart';");
  if (needsApp) buffer.writeln("import '../lib/routes.dart';");
  buffer
    ..writeln()
    ..writeln('void main() {');
  for (final entry in schemas.entries) {
    if (entry.value['type'] != 'object') continue;
    final name = entry.key;
    final sample = dartLiteral(_sample(entry.value, schemas, name));
    final constName = '${_lowerFirst(name)}Schema';
    buffer.writeln("  test('$name round-trips and validates', () {");
    buffer.writeln('    final Map<String, Object?> sample = $sample;');
    buffer.writeln('    final value = $name.fromJson(sample);');
    buffer.writeln('    expect($constName.validate(value.toJson()), isEmpty);');
    buffer.writeln(
      '    expect($name.fromJson(value.toJson()).toJson(), value.toJson());',
    );
    buffer.writeln('  });');
  }
  // For each endpoint that declares security, a "no credentials → 401" test.
  // It drives the shared buildApp, so the path to green is wiring enforcement
  // once there — never editing this test (over-claiming security is caught too).
  for (final e in secured) {
    buffer.writeln(
      "  test('${e.method.toUpperCase()} ${e.path} rejects a request "
      "without credentials', () async {",
    );
    buffer.writeln('    final client = TestClient(buildApp(), null);');
    buffer.writeln(
      "    expect((await client.${e.method}('${e.samplePath}')).status, 401);",
    );
    buffer.writeln('  });');
  }
  // For each endpoint with a required query parameter, a "missing it → 400"
  // test. Red until the handler reads the parameter with `c.query` (which 400s
  // on absence), the same buildApp-driven path to green.
  for (final e in requiredQuery) {
    buffer.writeln(
      "  test('${e.method.toUpperCase()} ${e.path} requires its query "
      "parameters', () async {",
    );
    buffer.writeln('    final client = TestClient(buildApp(), null);');
    buffer.writeln(
      "    expect((await client.${e.method}('${e.samplePath}')).status, 400);",
    );
    buffer.writeln('  });');
  }
  buffer.writeln('}');
  return buffer.toString();
}

/// One route+method singled out for a contract test.
class _Endpoint {
  _Endpoint(this.method, this.path, this.samplePath);
  final String method; // lower-case, e.g. 'post'
  final String path; // OpenAPI path, e.g. '/users/{id}'
  final String samplePath; // params filled, e.g. '/users/x'
}

String _samplePath(String openApiPath) =>
    openApiPath.replaceAllMapped(RegExp(r'\{[^}]+\}'), (_) => 'x');

List<_Endpoint> _securedEndpoints(Map<String, Object?> document) {
  final paths =
      (document['paths'] as Map?)?.cast<String, Object?>() ?? const {};
  return [
    for (final pathEntry in paths.entries)
      for (final opEntry
          in (pathEntry.value as Map).cast<String, Object?>().entries)
        if (_httpMethods.contains(opEntry.key))
          if ((opEntry.value as Map).cast<String, Object?>()['security']
              case final List<Object?> s when s.isNotEmpty)
            _Endpoint(opEntry.key, pathEntry.key, _samplePath(pathEntry.key)),
  ];
}

List<_Endpoint> _requiredQueryEndpoints(Map<String, Object?> document) {
  final paths =
      (document['paths'] as Map?)?.cast<String, Object?>() ?? const {};
  return [
    for (final pathEntry in paths.entries)
      for (final opEntry
          in (pathEntry.value as Map).cast<String, Object?>().entries)
        if (_httpMethods.contains(opEntry.key))
          if (_hasRequiredQuery((opEntry.value as Map).cast<String, Object?>()))
            _Endpoint(opEntry.key, pathEntry.key, _samplePath(pathEntry.key)),
  ];
}

bool _hasRequiredQuery(Map<String, Object?> op) {
  final parameters = op['parameters'];
  return parameters is List &&
      parameters.any(
        (p) => p is Map && p['in'] == 'query' && p['required'] == true,
      );
}

Object? _sample(
  Map<String, Object?> schema,
  Map<String, Map<String, Object?>> schemas,
  String name,
) {
  final required = _requiredOf(schema, name);
  final properties = _propertiesOf(schema, name);
  return {
    for (final key in required)
      if (properties[key] != null)
        key: _sampleValue(
          _asSchemaObject(properties[key], '$name.$key'),
          schemas,
        ),
  };
}

Object? _sampleValue(
  Map<String, Object?> prop,
  Map<String, Map<String, Object?>> schemas,
) {
  final inlineEnum = prop['enum'];
  if (inlineEnum is List && inlineEnum.isNotEmpty) return inlineEnum.first;
  final type = _resolve(prop, schemas);
  return switch (type) {
    _Prim(dart: 'String') => 'x',
    _Prim(dart: 'int') => 0,
    _Prim(dart: 'double') => 0,
    _Prim(dart: 'bool') => false,
    _Prim() => null,
    _Enum(:final name) => (schemas[name]!['enum'] as List).first,
    _Ref(:final name) => _sample(schemas[name]!, schemas, name),
    _ListOf() => const <Object?>[],
  };
}

// --- helpers --------------------------------------------------------------

const _httpMethods = {
  'get',
  'post',
  'put',
  'delete',
  'patch',
  'head',
  'options',
};

const _openapiTool = '''
import 'dart:io';

import 'package:keta_openapi/keta_openapi.dart';

import '../lib/routes.dart';

void main() {
  stdout.write(OpenApi.fromRoutes(buildApp().routes).toYaml());
}
''';

String _ketaPath(String openApiPath) => openApiPath.replaceAllMapped(
  RegExp(r'\{([^}]+)\}'),
  (m) => ':${m.group(1)}',
);

String _refName(String ref) => ref.split('/').last;

Iterable<String> _refsIn(Object? node) sync* {
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key == r'$ref' && entry.value is String) {
        yield _refName(entry.value as String);
      } else {
        yield* _refsIn(entry.value);
      }
    }
  } else if (node is List) {
    for (final item in node) {
      yield* _refsIn(item);
    }
  }
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';

/// Rejects schema names that aren't valid Dart type identifiers, and any two
/// whose `xSchema` const names collide (e.g. `Foo` and `foo`).
void _checkSchemaNames(Map<String, Map<String, Object?>> schemas) {
  final constNames = <String, String>{};
  for (final name in schemas.keys) {
    if (!_isValidIdentifier(name) || _reservedWords.contains(name)) {
      throw ScaffoldError(
        'schema name "$name" is not a valid Dart type name; rename it',
      );
    }
    final constName = '${_lowerFirst(name)}Schema';
    final existing = constNames[constName];
    if (existing != null) {
      throw ScaffoldError(
        'schemas "$existing" and "$name" both map to const "$constName"',
      );
    }
    constNames[constName] = name;
  }
}

/// Rejects self- or mutually-recursive `$ref` graphs: a recursive const Schema
/// is a compile-time cycle and a recursive contract-test sample never
/// terminates, so recursion is outside the const-Schema subset.
void _checkRefCycles(Map<String, Map<String, Object?>> schemas) {
  final done = <String>{};
  final stack = <String>{};
  void visit(String name) {
    if (done.contains(name)) return;
    if (!stack.add(name)) {
      throw ScaffoldError(
        'schema "$name" is part of a reference cycle; the const Schema '
        'subset does not support recursive types',
      );
    }
    for (final ref in _refsIn(schemas[name] ?? const {})) {
      if (schemas.containsKey(ref)) visit(ref);
    }
    stack.remove(name);
    done.add(name);
  }

  for (final name in schemas.keys) {
    visit(name);
  }
}

final RegExp _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
bool _isValidIdentifier(String s) => _identifierPattern.hasMatch(s);

/// Maps an arbitrary JSON name to a valid, non-reserved Dart identifier.
String _sanitizeIdentifier(String name) {
  var cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (cleaned.isEmpty) cleaned = 'field';
  if (RegExp(r'^[0-9]').hasMatch(cleaned)) cleaned = 'f$cleaned';
  if (_reservedWords.contains(cleaned)) cleaned = '${cleaned}_';
  return cleaned;
}

String _uniqueIdent(String base, Set<String> used) {
  var candidate = base;
  var i = 1;
  while (!used.add(candidate)) {
    candidate = '$base$i';
    i++;
  }
  return candidate;
}

const _reservedWords = {
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'while',
  'with',
  'yield',
};
