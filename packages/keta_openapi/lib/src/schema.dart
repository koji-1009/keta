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
  const Schema(this.name, this.json, {this.deps = const []});
  final String name;
  final Map<String, Object?> json;
  final List<Schema> deps;

  /// Validates [value] against this schema, returning a violation message per
  /// problem (each carrying a JSON path). An empty list means valid.
  List<String> validate(Object? value) {
    final errors = <String>[];
    _validate(json, value, r'$', errors, _refIndex());
    return errors;
  }

  /// Validates [value] and returns it unchanged, throwing a [BadRequest] with
  /// the violation list as detail on any problem. Validation is the gate;
  /// typing the result is the mapper's job
  /// (`Dto.fromJson(schema.require(body) as Map<String, Object?>)`).
  Object? require(Object? value) {
    final errors = validate(value);
    if (errors.isNotEmpty) {
      throw BadRequest('validation failed', errors);
    }
    return value;
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

void _validate(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
) {
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

  final before = errors.length;
  switch (schema['type']) {
    case null:
      // No `type` declared at all: legitimate for an enum-only or `oneOf`
      // fragment — nothing to check here beyond what already ran above.
      break;
    case 'object':
      _validateObject(schema, value, path, errors, refs);
    case 'array':
      _validateArray(schema, value, path, errors, refs);
    case 'string':
      if (value is! String) {
        errors.add('$path: expected string, got ${_typeName(value)}');
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
    default:
      // A typo'd type name, a JSON Schema type array (`['string', 'null']`),
      // or any other value outside the canonical subset (§4) must not be a
      // silent pass — that would open the boundary `require()` is supposed to
      // gate.
      errors.add("$path: unknown schema type '${schema['type']}'");
  }
  // `enum` restricts the value regardless of type (a string, integer, or
  // type-less enum), and only once the value has passed its type check. The
  // membership test compares against the raw list so a malformed enum
  // definition can never turn a request into a cast crash (500).
  if (errors.length == before) {
    _validateEnum(schema, value, path, errors);
  }
}

void _validateObject(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
) {
  if (value is! Map) {
    errors.add('$path: expected object, got ${_typeName(value)}');
    return;
  }
  // No `.cast<String>()`: a malformed `required` (not a list, or a list with
  // non-string entries) must become a violation rather than a cast crash, the
  // same posture already taken for `enum` below.
  final requiredRaw = schema['required'];
  final List<String> required;
  if (requiredRaw == null) {
    required = const [];
  } else if (requiredRaw is List) {
    required = requiredRaw.whereType<String>().toList();
  } else {
    errors.add(
      '$path: "required" must be a list of strings, got '
      '${_typeName(requiredRaw)}',
    );
    required = const [];
  }
  for (final key in required) {
    if (!value.containsKey(key)) {
      errors.add('$path.$key: required property is missing');
    }
  }
  final properties =
      (schema['properties'] as Map?)?.cast<String, Object?>() ?? const {};
  for (final entry in properties.entries) {
    if (value.containsKey(entry.key)) {
      final v = value[entry.key];
      // A null for an optional property is accepted — the canonical toJson
      // omits nulls, so an explicit null means "absent".
      if (v == null && !required.contains(entry.key)) continue;
      // No `as Map<String, Object?>`: a malformed property fragment (authored
      // as a string, a list, ...) must become a violation on that property
      // rather than a cast crash.
      final sub = entry.value;
      if (sub is! Map<String, Object?>) {
        errors.add(
          '$path.${entry.key}: schema fragment must be an object, got '
          '${_typeName(sub)}',
        );
        continue;
      }
      _validate(sub, v, '$path.${entry.key}', errors, refs);
    }
  }
  // additionalProperties governs undeclared keys: a schema validates each of
  // them (Map<String, T>), while `false` closes the object and rejects them.
  final additional = schema['additionalProperties'];
  if (additional == false) {
    for (final key in value.keys) {
      if (!properties.containsKey(key)) {
        errors.add(
          '$path.$key: unexpected property (additionalProperties is false)',
        );
      }
    }
  } else if (additional is Map<String, Object?>) {
    for (final entry in value.entries) {
      if (!properties.containsKey(entry.key)) {
        _validate(additional, entry.value, '$path.${entry.key}', errors, refs);
      }
    }
  }
}

void _validateArray(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
) {
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

void _validateEnum(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
) {
  final values = schema['enum'];
  // No `.cast<String>()`: comparing against the raw list keeps a malformed
  // enum definition (or a non-string enum) from throwing during validation.
  if (values is List && !values.contains(value)) {
    errors.add('$path: "$value" is not one of ${values.join(', ')}');
  }
}

void _validateOneOf(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
) {
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
  // With no explicit mapping, OpenAPI 3.1 maps the discriminator value to the
  // schema of the same name implicitly. An explicit mapping is authoritative:
  // a tag absent from it has no variant.
  final String ref;
  if (mapping == null) {
    ref = '#/components/schemas/$tag';
  } else {
    final mapped = mapping[tag];
    if (mapped is! String) {
      errors.add('$path.$discriminator: "$tag" has no variant');
      return;
    }
    ref = mapped;
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
