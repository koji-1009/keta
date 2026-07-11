library;

import 'package:keta/keta.dart';

/// A named JSON Schema fragment that is the single source of truth for a type:
/// it drives OpenAPI output, runtime boundary validation, and (via keta_lints)
/// contract tests.
///
/// [json] is a JSON Schema fragment restricted to the canonical subset:
/// primitives, `T?` (optional), `List<T>`, `Map<String, T>`, enums, `$ref` to
/// another schema, and `oneOf` + `discriminator` for sealed types. [deps] lists
/// referenced schemas so a walker can collect them transitively.
final class Schema {
  final String name;
  final Map<String, Object?> json;
  final List<Schema> deps;

  const Schema(this.name, this.json, {this.deps = const []});

  /// Validates [value] against this schema, returning a violation message per
  /// problem (each carrying a JSON path). An empty list means valid.
  List<String> validate(Object? value) {
    final errors = <String>[];
    _validate(json, value, r'$', errors, _refIndex());
    return errors;
  }

  /// Validates [value] and returns it as `T`, throwing `KetaException(400)`
  /// with the violation list as detail on any problem.
  T require<T>(Object? value) {
    final errors = validate(value);
    if (errors.isNotEmpty) {
      throw KetaException(400, 'validation failed', errors);
    }
    return value as T;
  }

  /// Indexes this schema and its transitive [deps] by their `$ref` target.
  Map<String, Schema> _refIndex() {
    final index = <String, Schema>{};
    void walk(Schema s) {
      final key = '#/components/schemas/${s.name}';
      if (index.containsKey(key)) return;
      index[key] = s;
      s.deps.forEach(walk);
    }

    walk(this);
    return index;
  }
}

void _validate(Map<String, Object?> schema, Object? value, String path,
    List<String> errors, Map<String, Schema> refs) {
  final ref = schema[r'$ref'];
  if (ref is String) {
    final target = refs[ref];
    if (target == null) {
      errors.add('$path: unknown schema reference "$ref"');
    } else {
      _validate(target.json, value, path, errors, refs);
    }
    return;
  }

  if (schema['oneOf'] is List) {
    _validateOneOf(schema, value, path, errors, refs);
    return;
  }

  switch (schema['type']) {
    case 'object':
      _validateObject(schema, value, path, errors, refs);
    case 'array':
      _validateArray(schema, value, path, errors, refs);
    case 'string':
      if (value is! String) {
        errors.add('$path: expected string, got ${_typeName(value)}');
      } else {
        _validateEnum(schema, value, path, errors);
      }
    case 'integer':
      if (value is! int) {
        errors.add('$path: expected integer, got ${_typeName(value)}');
      }
    case 'number':
      if (value is! num) {
        errors.add('$path: expected number, got ${_typeName(value)}');
      }
    case 'boolean':
      if (value is! bool) {
        errors.add('$path: expected boolean, got ${_typeName(value)}');
      }
  }
}

void _validateObject(Map<String, Object?> schema, Object? value, String path,
    List<String> errors, Map<String, Schema> refs) {
  if (value is! Map) {
    errors.add('$path: expected object, got ${_typeName(value)}');
    return;
  }
  final required = (schema['required'] as List?)?.cast<String>() ?? const [];
  for (final key in required) {
    if (!value.containsKey(key)) {
      errors.add('$path.$key: required property is missing');
    }
  }
  final properties =
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  for (final entry in properties.entries) {
    if (value.containsKey(entry.key)) {
      _validate(entry.value as Map<String, Object?>, value[entry.key],
          '$path.${entry.key}', errors, refs);
    }
  }
}

void _validateArray(Map<String, Object?> schema, Object? value, String path,
    List<String> errors, Map<String, Schema> refs) {
  if (value is! List) {
    errors.add('$path: expected array, got ${_typeName(value)}');
    return;
  }
  final items = schema['items'] as Map<String, Object?>?;
  if (items == null) return;
  for (var i = 0; i < value.length; i++) {
    _validate(items, value[i], '$path[$i]', errors, refs);
  }
}

void _validateEnum(Map<String, Object?> schema, String value, String path,
    List<String> errors) {
  final values = (schema['enum'] as List?)?.cast<String>();
  if (values != null && !values.contains(value)) {
    errors.add('$path: "$value" is not one of ${values.join(', ')}');
  }
}

void _validateOneOf(Map<String, Object?> schema, Object? value, String path,
    List<String> errors, Map<String, Schema> refs) {
  if (value is! Map) {
    errors.add('$path: expected object, got ${_typeName(value)}');
    return;
  }
  final discriminator =
      (schema['discriminator'] as Map?)?['propertyName'] as String?;
  if (discriminator == null) {
    errors.add('$path: oneOf without a discriminator is not supported');
    return;
  }
  final tag = value[discriminator];
  if (tag is! String) {
    errors.add('$path.$discriminator: discriminator must be a string');
    return;
  }
  final mapping =
      (schema['discriminator'] as Map)['mapping'] as Map<String, Object?>?;
  final ref = mapping?[tag];
  if (ref is! String) {
    errors.add('$path.$discriminator: "$tag" has no variant');
    return;
  }
  final target = refs[ref];
  if (target == null) {
    errors.add('$path: unknown schema reference "$ref"');
    return;
  }
  _validate(target.json, value, path, errors, refs);
}

String _typeName(Object? value) => switch (value) {
      null => 'null',
      String() => 'string',
      int() => 'integer',
      double() => 'number',
      bool() => 'boolean',
      List() => 'array',
      Map() => 'object',
      _ => value.runtimeType.toString(),
    };
