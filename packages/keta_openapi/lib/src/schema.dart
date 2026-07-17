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
///
/// ## The two-posture rule
///
/// Every mistake [validate] can trip over is one of exactly two kinds, and
/// each gets exactly one posture — never a third:
///
///  1. **A malformed SCHEMA fragment** — `items` that isn't an object,
///     `required` that isn't a list of strings, a `$ref` absent from [deps], a
///     `type` that is misspelled, and so on — is the *schema author's* defect:
///     whoever wrote the `const Schema(...)` fragment made a mistake that no
///     request from any client could ever trigger or fix. This throws a
///     descriptive [StateError] naming the schema and the offending key. It is
///     never caught here, so it propagates as an uncaught defect and becomes a
///     500 under keta's error rule — it must never be blamed on the client via
///     a violation, and it must never be swallowed as a silent pass, because
///     both of those hide an authoring bug that [validate] exists to catch.
///  2. **Invalid INSTANCE data** — a request body missing a required
///     property, a string where a number was declared, an enum value outside
///     its declared set — is the *client's* defect: the schema fragment
///     itself is well-formed, but the value checked against it is not. This
///     adds a violation message to the returned list, which [require] turns
///     into a [BadRequest] (400).
///
/// A prior version of this validator applied three different postures
/// (violation, a bare `as` cast that crashed with a raw `TypeError`, or a
/// silent pass) to what was really the same class of mistake — schema
/// authoring damage — depending on which line happened to notice it. That
/// inconsistency is the bug this class now forecloses: every code path below
/// is one of the two postures above, never a third.
final class Schema {
  const Schema(this.name, this.json, {this.deps = const []});
  final String name;
  final Map<String, Object?> json;
  final List<Schema> deps;

  /// Validates [value] against this schema, returning a violation message per
  /// problem (each carrying a JSON path). An empty list means valid.
  ///
  /// A malformed schema fragment reached along the way (see the class doc's
  /// two-posture rule) throws a [StateError] instead of appearing in this
  /// list — that defect is never the client's to be told about.
  List<String> validate(Object? value) {
    final errors = <String>[];
    _validate(json, value, r'$', errors, _refIndex(), name);
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

  /// [require]s [value], then hands it back typed as a JSON object map — the
  /// shape every write handler needs before it reaches a `Dto.fromJson`.
  ///
  /// Without this, every call site repeated
  /// `schema.require(body) as Map<String, Object?>`. That cast is [require]'s
  /// contract leaking through: `require`'s return type is `Object?` because a
  /// schema is not always `type: object` (a bare list or string is a
  /// legitimate schema too), so it cannot promise a map back, and the cast at
  /// each call site stood in for that promise. But whether the value is
  /// actually a map does not depend on the caller at all — only on what the
  /// *schema* declares and what the *client* sent — so it is validation's
  /// job, not each handler's. A schema declared `type: object` always
  /// produces a map here once [require] accepts it; a mismatch can only come
  /// from a schema with no such restriction (enum-only, `oneOf`-typed, or
  /// untyped) paired with client JSON that validates but isn't an object
  /// (an array, a string, ...) — that is exactly the shape of an instance-data
  /// problem the class doc's posture (2) covers, so it is a [BadRequest], not
  /// a [TypeError].
  Map<String, Object?> requireMap(Object? value) {
    final required = require(value);
    if (required is Map<String, Object?>) return required;
    throw BadRequest(
      'expected a JSON object',
      '\$: expected object, got ${_typeName(required)}',
    );
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

/// Throws the [StateError] a malformed SCHEMA fragment gets under the class
/// doc's two-posture rule — never a violation, never a silent pass.
/// [schemaName] and [path] locate the fragment (the schema currently being
/// read, and where in the value tree its reader was reached); [key] names the
/// JSON-Schema keyword that is malformed; [problem] states what is wrong with
/// the value found there.
Never _authoringDefect(
  String schemaName,
  String path,
  String key,
  String problem,
) {
  throw StateError('schema "$schemaName" at $path: "$key" $problem');
}

void _validate(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
  String schemaName,
) {
  if (schema.containsKey(r'$ref')) {
    final ref = schema[r'$ref'];
    if (ref is! String) {
      _authoringDefect(
        schemaName,
        path,
        r'$ref',
        'must be a string, got ${_typeName(ref)}',
      );
    }
    final target = refs[ref];
    if (target == null) {
      _authoringDefect(
        schemaName,
        path,
        r'$ref',
        'references unknown schema "$ref" (missing from deps)',
      );
    }
    // The fragment being read from here on is `target`'s, not the one that
    // held the `$ref` — a defect found beneath it must name its own schema,
    // not the referrer's.
    _validate(target.json, value, path, errors, refs, target.name);
    return;
  }

  if (schema.containsKey('oneOf')) {
    final oneOf = schema['oneOf'];
    if (oneOf is! List) {
      _authoringDefect(
        schemaName,
        path,
        'oneOf',
        'must be a list, got ${_typeName(oneOf)}',
      );
    }
    _validateOneOf(schema, value, path, errors, refs, schemaName);
    return;
  }

  final before = errors.length;
  switch (schema['type']) {
    case null:
      // No `type` declared at all: legitimate for an enum-only or `oneOf`
      // fragment — nothing to check here beyond what already ran above.
      break;
    case 'object':
      _validateObject(schema, value, path, errors, refs, schemaName);
    case 'array':
      _validateArray(schema, value, path, errors, refs, schemaName);
    case 'string':
      if (value is! String) {
        errors.add('$path: expected string, got ${_typeName(value)}');
      }
    case 'integer':
      // Deliberately narrower than JSON Schema 2020-12, which admits a
      // zero-fraction number (`1.0`) as a valid `integer` instance — this
      // validator does not, because `value is! int` rejects it outright.
      // This is not an oversight; it is a deliberate agreement with the
      // canonical mapper, which reads `json['x'] as int`. If `1.0` passed
      // validation here, it would sail through as "valid" and then crash
      // that cast (a 500) on exactly the payload validation exists to gate
      // — the boundary would have lied about what it let through.
      // Predictability between the two beats spec purity: what counts as an
      // integer is decided once, and validation and mapping agree on it.
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
      // or any other value outside the canonical subset is authoring damage:
      // nothing about the *value* being checked could ever make `schema` a
      // recognized type. Posture (i), not a violation.
      _authoringDefect(
        schemaName,
        path,
        'type',
        'is not a recognized schema type, got ${schema['type']}',
      );
  }
  // `enum` restricts the value regardless of type (a string, integer, or
  // type-less enum), and only once the value has passed its type check.
  if (errors.length == before) {
    _validateEnum(schema, value, path, errors, schemaName);
  }
}

void _validateObject(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
  String schemaName,
) {
  if (value is! Map) {
    errors.add('$path: expected object, got ${_typeName(value)}');
    return;
  }
  final requiredRaw = schema['required'];
  final List<String> required;
  if (requiredRaw == null) {
    required = const [];
  } else if (requiredRaw is List) {
    // A property name is always a string, so a non-string entry inside an
    // otherwise-list `required` is the same authoring mistake as a `required`
    // that isn't a list at all — it must not be silently dropped the way a
    // `.whereType<String>()` would.
    for (final entry in requiredRaw) {
      if (entry is! String) {
        _authoringDefect(
          schemaName,
          path,
          'required',
          'must be a list of strings, found a ${_typeName(entry)} entry',
        );
      }
    }
    required = requiredRaw.cast<String>();
  } else {
    _authoringDefect(
      schemaName,
      path,
      'required',
      'must be a list of strings, got ${_typeName(requiredRaw)}',
    );
  }
  for (final key in required) {
    if (!value.containsKey(key)) {
      errors.add('$path.$key: required property is missing');
    }
  }
  final propertiesRaw = schema['properties'];
  final Map<String, Object?> properties;
  if (propertiesRaw == null) {
    properties = const {};
  } else if (propertiesRaw is Map) {
    properties = propertiesRaw.cast<String, Object?>();
  } else {
    _authoringDefect(
      schemaName,
      path,
      'properties',
      'must be an object, got ${_typeName(propertiesRaw)}',
    );
  }
  for (final entry in properties.entries) {
    if (value.containsKey(entry.key)) {
      final v = value[entry.key];
      // A null for an optional property is accepted — the canonical toJson
      // omits nulls, so an explicit null means "absent".
      if (v == null && !required.contains(entry.key)) continue;
      final sub = entry.value;
      if (sub is! Map<String, Object?>) {
        _authoringDefect(
          schemaName,
          '$path.${entry.key}',
          'properties.${entry.key}',
          'must be an object schema fragment, got ${_typeName(sub)}',
        );
      }
      _validate(sub, v, '$path.${entry.key}', errors, refs, schemaName);
    }
  }
  // additionalProperties governs undeclared keys: absent leaves them
  // unconstrained, a schema validates each of them (`Map<String, T>`), and
  // `false` closes the object and rejects them. Anything else — `true`, a
  // string, a number — is outside that canonical subset.
  final additional = schema['additionalProperties'];
  if (additional == null) {
    // Absent: legitimately open, nothing to check.
  } else if (additional == false) {
    for (final key in value.keys) {
      if (!properties.containsKey(key)) {
        errors.add(
          '$path.$key: unexpected property (additionalProperties is false)',
        );
      }
    }
  } else if (additional is Map) {
    final additionalSchema = additional.cast<String, Object?>();
    for (final entry in value.entries) {
      if (!properties.containsKey(entry.key)) {
        _validate(
          additionalSchema,
          entry.value,
          '$path.${entry.key}',
          errors,
          refs,
          schemaName,
        );
      }
    }
  } else {
    _authoringDefect(
      schemaName,
      path,
      'additionalProperties',
      'must be false or an object schema, got ${_typeName(additional)}',
    );
  }
}

void _validateArray(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
  String schemaName,
) {
  if (value is! List) {
    errors.add('$path: expected array, got ${_typeName(value)}');
    return;
  }
  final itemsRaw = schema['items'];
  if (itemsRaw == null) return;
  if (itemsRaw is! Map) {
    _authoringDefect(
      schemaName,
      path,
      'items',
      'must be an object schema fragment, got ${_typeName(itemsRaw)}',
    );
  }
  final items = itemsRaw.cast<String, Object?>();
  for (var i = 0; i < value.length; i++) {
    _validate(items, value[i], '$path[$i]', errors, refs, schemaName);
  }
}

void _validateEnum(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  String schemaName,
) {
  if (!schema.containsKey('enum')) return;
  final values = schema['enum'];
  if (values is! List) {
    _authoringDefect(
      schemaName,
      path,
      'enum',
      'must be a list, got ${_typeName(values)}',
    );
  }
  // Membership is checked against the raw list, not narrowed to one type: a
  // mixed-type enum (`['a', 1]`) is legitimate JSON Schema — members need not
  // share a type — so that is instance-data business, not a malformed schema.
  if (!values.contains(value)) {
    errors.add('$path: "$value" is not one of ${values.join(', ')}');
  }
}

void _validateOneOf(
  Map<String, Object?> schema,
  Object? value,
  String path,
  List<String> errors,
  Map<String, Schema> refs,
  String schemaName,
) {
  if (value is! Map) {
    errors.add('$path: expected object, got ${_typeName(value)}');
    return;
  }
  final discriminatorRaw = schema['discriminator'];
  if (discriminatorRaw is! Map) {
    _authoringDefect(
      schemaName,
      path,
      'discriminator',
      'oneOf requires an object with a "propertyName", got '
          '${_typeName(discriminatorRaw)}',
    );
  }
  final discriminator = discriminatorRaw.cast<String, Object?>();
  final propertyName = discriminator['propertyName'];
  if (propertyName is! String) {
    _authoringDefect(
      schemaName,
      path,
      'discriminator.propertyName',
      'must be a string, got ${_typeName(propertyName)}',
    );
  }
  final tag = value[propertyName];
  if (tag is! String) {
    errors.add('$path.$propertyName: discriminator must be a string');
    return;
  }
  final mappingRaw = discriminator['mapping'];
  final Map<String, Object?>? mapping;
  if (mappingRaw == null) {
    mapping = null;
  } else if (mappingRaw is Map) {
    mapping = mappingRaw.cast<String, Object?>();
  } else {
    _authoringDefect(
      schemaName,
      path,
      'discriminator.mapping',
      'must be an object of ref strings, got ${_typeName(mappingRaw)}',
    );
  }
  // With no explicit mapping, OpenAPI 3.1 maps the discriminator value to the
  // schema of the same name implicitly, so the ref is built straight from the
  // client-supplied tag: whether it resolves depends on what the client sent,
  // exactly like an enum membership check, so a miss here stays a violation.
  // An explicit mapping is different — it is a fixed dict the schema author
  // wrote, so a miss inside it (`mapped is! String`, "tag not a mapping key")
  // is unresolvable-by-any-request instance business too (the *set* of valid
  // tags is closed by the mapping, and the client's tag falls outside it).
  // But once a tag *is* a mapping key, the ref it names is fully determined
  // by the schema alone — a dangling one there is the author's mistake, not
  // reachable by any choice of client tag.
  final String ref;
  final bool fromMapping;
  if (mapping == null) {
    ref = '#/components/schemas/$tag';
    fromMapping = false;
  } else {
    final mapped = mapping[tag];
    if (mapped is! String) {
      errors.add('$path.$propertyName: "$tag" has no variant');
      return;
    }
    ref = mapped;
    fromMapping = true;
  }
  final target = refs[ref];
  if (target == null) {
    if (fromMapping) {
      _authoringDefect(
        schemaName,
        path,
        'discriminator.mapping',
        'maps "$tag" to "$ref", which is not a known schema (missing from '
            'deps)',
      );
    }
    errors.add('$path.$propertyName: "$tag" has no variant');
    return;
  }
  _validate(target.json, value, path, errors, refs, target.name);
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
