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
    contractTest: _generateContractTest(schemas),
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
      entry.key.toString(): (entry.value as Map).cast<String, Object?>(),
  };
}

bool _isEnum(Map<String, Object?> schema) =>
    schema['type'] == 'string' && schema['enum'] is List;

// --- DTOs -----------------------------------------------------------------

String _generateDtos(Map<String, Map<String, Object?>> schemas) {
  final buffer = StringBuffer()
    ..writeln("import 'package:keta_openapi/keta_openapi.dart';")
    ..writeln();
  for (final entry in schemas.entries) {
    final name = entry.key;
    final schema = entry.value;
    if (_isEnum(schema)) {
      _writeEnum(buffer, name, schema);
    } else if (schema['type'] == 'object') {
      _writeClass(buffer, name, schema, schemas);
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

void _writeEnum(StringBuffer buffer, String name, Map<String, Object?> schema) {
  final values = (schema['enum'] as List).cast<String>();
  // Enum constants map name↔wire via `.name`/`.byName`, so each value must be a
  // valid, non-reserved Dart identifier as-is. Reject (don't emit broken code).
  for (final v in values) {
    if (!_isValidIdentifier(v) || _reservedWords.contains(v)) {
      throw ScaffoldError(
        'enum "$name" value "$v" is not a valid Dart identifier; '
        'materialize this enum by hand',
      );
    }
  }
  buffer.writeln('enum $name { ${values.join(', ')} }');
  buffer.writeln();
}

void _writeClass(
  StringBuffer buffer,
  String name,
  Map<String, Object?> schema,
  Map<String, Map<String, Object?>> schemas,
) {
  final required = (schema['required'] as List?)?.cast<String>() ?? const [];
  final properties =
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  // JSON property names become valid, unique Dart identifiers; the original
  // wire key is kept for the fromJson/toJson maps.
  final usedNames = <String>{};
  final fields = [
    for (final entry in properties.entries)
      _Field(
        entry.key,
        _uniqueIdent(_sanitizeIdentifier(entry.key), usedNames),
        _resolve((entry.value as Map).cast<String, Object?>(), schemas),
        required.contains(entry.key),
      ),
  ];

  buffer.writeln('class $name {');
  for (final f in fields) {
    buffer.writeln('  final ${f.dartType} ${f.dartName};');
  }
  // Every field is final and the constructor is initializing-formals only, so
  // the generated DTO is always const-eligible; emit a const constructor so
  // callers can build const instances (and `prefer_const_constructors` fires).
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
    'array' => _ListOf(
      _resolve((prop['items'] as Map).cast<String, Object?>(), schemas),
    ),
    _ => throw ScaffoldError('unsupported property schema: $prop'),
  };
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
      final doc = _routeDoc(op);
      buffer.writeln("  app.$method('${_ketaPath(pathEntry.key)}',");
      buffer.writeln(
        "      (c) => throw const NotImplementedYet('not implemented')"
        '${doc == null ? '' : ','}',
      );
      if (doc != null) buffer.writeln('      doc: $doc,');
      buffer.writeln('  );');
    }
  }
  buffer.writeln('}');
  return buffer.toString();
}

String? _routeDoc(Map<String, Object?> op) {
  final parts = <String>[];
  final summary = op['summary'];
  if (summary is String) parts.add('summary: ${dartStringLiteral(summary)}');
  final request = _schemaRefName(((op['requestBody'] as Map?)?['content']));
  if (request != null) parts.add('requestBody: ${_lowerFirst(request)}Schema');
  final ok = (op['responses'] as Map?)?['200'];
  final response = _schemaRefName((ok as Map?)?['content']);
  if (response != null) parts.add('response: ${_lowerFirst(response)}Schema');
  if (parts.isEmpty) return null;
  return 'RouteDoc(${parts.join(', ')})';
}

String? _schemaRefName(Object? content) {
  if (content is! Map) return null;
  final json = content['application/json'];
  final schema = json is Map ? json['schema'] : null;
  final ref = schema is Map ? schema[r'$ref'] : null;
  return ref is String ? _refName(ref) : null;
}

String _generateContractTest(Map<String, Map<String, Object?>> schemas) {
  final buffer = StringBuffer()
    ..writeln("import 'package:test/test.dart';")
    ..writeln()
    ..writeln("import '../lib/dtos.dart';")
    ..writeln()
    ..writeln('void main() {');
  for (final entry in schemas.entries) {
    if (entry.value['type'] != 'object') continue;
    final name = entry.key;
    final sample = dartLiteral(_sample(entry.value, schemas));
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
  buffer.writeln('}');
  return buffer.toString();
}

Object? _sample(
  Map<String, Object?> schema,
  Map<String, Map<String, Object?>> schemas,
) {
  final required = (schema['required'] as List?)?.cast<String>() ?? const [];
  final properties =
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  return {
    for (final key in required)
      if (properties[key] != null)
        key: _sampleValue(
          (properties[key] as Map).cast<String, Object?>(),
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
    _Ref(:final name) => _sample(schemas[name]!, schemas),
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

import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';

import '../lib/routes.dart';

void main() {
  final app = App<Object?>();
  register(app);
  stdout.write(OpenApi.fromRoutes(app.routes).toYaml());
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
