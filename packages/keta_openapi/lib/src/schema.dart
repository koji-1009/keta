library;

import 'dart:collection';

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
///
/// ## Validation keywords are enforced, not decoration
///
/// The document does not lie: a constraint that appears in the emitted OpenAPI
/// must also be applied at the runtime boundary. Beyond the shape checks
/// (`type`/`required`/`enum`/nested/`oneOf`/`additionalProperties`), [validate]
/// enforces every scalar validation keyword this schema can carry, with JSON
/// Schema 2020-12 semantics, and each applies only to an instance of the
/// keyword's own type (a `minLength` on a number instance is inapplicable, not
/// a failure — exactly as the spec says):
///
///  - **`minLength` / `maxLength`** (strings): length is counted in Unicode
///    **code points** (`String.runes.length`), not UTF-16 code units, so an
///    astral-plane character such as `'😀'` counts as length 1, not 2.
///  - **`pattern`** (strings): compiled as a Dart [RegExp] (the ECMAScript
///    dialect JSON Schema prescribes) and matched **unanchored** — a partial
///    match anywhere in the string satisfies it, per JSON Schema. The regex
///    itself carries no ReDoS guard (a hostile pattern such as `^(a+)+$`
///    backtracks catastrophically), so its safety rests on never running it
///    over an arbitrarily long string, and the boundary enforces that in two
///    layers. First, the `maxLength` bound *gates* the regex: when the schema
///    declares `maxLength` and the value exceeds it, the value is already
///    condemned, so `pattern` is skipped entirely rather than fed the
///    over-long input — pairing `pattern` with a `maxLength` keeps validation
///    fully under the author's control. Second, an absolute backstop caps the
///    length of any string the regex will ever see at [_patternInputCeiling]
///    code points, for the schema that omits `maxLength` (or sets one above
///    the ceiling): a longer string is reported as a violation instead of
///    being pattern-matched, so the megabyte-scale body the request cap admits
///    can never reach an unguarded regex.
///  - **`format`** (strings): only a crisp, unambiguous set is enforced —
///    `date-time` and `date` (RFC 3339) and `uuid` (RFC 4122 string form).
///    Every other `format` value (`email`, `hostname`, `binary`, …) is an
///    annotation per the spec: it is emitted but **not** enforced, and never a
///    violation.
///  - **`minimum` / `maximum`** and **`exclusiveMinimum` / `exclusiveMaximum`**
///    (numbers): numeric comparison; the exclusive variants are the 2020-12
///    numeric form (a bound, not a boolean flag).
///  - **`multipleOf`** (numbers): `value / multipleOf` must be an integer.
///    Integer operands are checked exactly (`value % multipleOf == 0`);
///    fractional operands (e.g. `multipleOf: 0.1`) are checked with a small
///    relative tolerance so `0.3` counts as a multiple of `0.1` despite binary
///    floating-point error, while `0.35` does not. A `multipleOf` that is not
///    greater than zero is authoring damage.
///  - **`minItems` / `maxItems`** (arrays): element count.
///  - **`uniqueItems`** (arrays): when `true`, no two elements may be equal by
///    **deep JSON-value equality** (structural, not identity), so two equal
///    nested objects collide. The check is O(n²), so — symmetrically with
///    `pattern` — its cost is bounded in two layers: a `maxItems` the array
///    exceeds *gates* the scan out (the array is already condemned), and an
///    absolute [_uniqueItemsCeiling] backstops the schema that omits `maxItems`,
///    reporting an over-ceiling array as a violation instead of scanning it. An
///    endpoint that legitimately needs uniqueness over more items declares an
///    explicit `maxItems` rather than leaning on the backstop.
///
/// A violated value keyword is instance data — posture (2), a violation. A
/// malformed keyword *value* (a `minLength` that isn't a non-negative integer,
/// a `pattern` that isn't a valid regular expression, a `multipleOf` ≤ 0, a
/// non-boolean `uniqueItems`, …) is authoring damage — posture (1), a
/// [StateError].
///
/// ## What you can write takes effect; what doesn't take effect can't be written
///
/// The keywords above are every validation keyword keta enforces. A schema may
/// still *carry* any JSON string as a key, but a key that is a recognized JSON
/// Schema **validation** keyword keta does **not** enforce — `const`, `allOf`,
/// `anyOf`, `not`, `if`/`then`/`else`, `dependentRequired`, `dependentSchemas`,
/// `prefixItems`, `contains`, `minContains`, `maxContains`, `minProperties`,
/// `maxProperties`, `patternProperties`, `propertyNames`, `unevaluatedItems`,
/// or `unevaluatedProperties` — is authoring damage: it would be emitted into
/// the document as a promise the boundary silently breaks. [validate] throws a
/// [StateError] naming it (posture (1)). Pure annotations that only describe
/// the document (`description`, `title`, `example`, `examples`, `default`,
/// `deprecated`, `readOnly`, `writeOnly`, …) are not validation keywords and
/// pass through untouched.
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
    _validate(json, value, _Path.root, errors, _refIndex(), name);
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
  ///
  /// The result is memoized in [_refIndexCache], keyed on `this` by identity:
  /// a [Schema]'s `deps` graph is fixed at construction (the fields are `final`
  /// and the whole graph is authored as `const`), so the index is a pure
  /// function of the instance and is safe to build once and reuse across every
  /// [validate]/[require] call. The walk itself has no posture-(1) throw — its
  /// only dedup is the silent `containsKey` guard below, which keeps the first
  /// binding of a duplicated name — so memoizing changes nothing observable:
  /// the first build wins, exactly as a fresh build's first `walk` did, and the
  /// graph's immutability means a later build could only reproduce it. Const
  /// instances are canonicalized, so structurally identical schemas share one
  /// cache entry (their indexes would be equal anyway); [listSchema]'s
  /// non-`const` results are distinct instances that each memoize their own.
  Map<String, Schema> _refIndex() {
    final cached = _refIndexCache[this];
    if (cached != null) return cached;
    final index = <String, Schema>{};
    void walk(Schema s) {
      final key = '#/components/schemas/${s.name}';
      if (index.containsKey(key)) return;
      index[key] = s;
      s.deps.forEach(walk);
    }

    walk(this);
    _refIndexCache[this] = index;
    return index;
  }
}

/// Per-[Schema] memo of [Schema._refIndex], keyed on the instance by identity.
/// An [Expando] holds the entry weakly, so it costs nothing once a schema is
/// unreachable, and it accepts a `const`-canonicalized [Schema] as a key (only
/// numbers, strings, booleans, `null`, and records are barred — a user class
/// instance, const or not, is a valid key on this SDK). The `$ref` graph is
/// immutable, so a cached index never goes stale.
final Expando<Map<String, Schema>> _refIndexCache = Expando();

/// Builds the canonical list-endpoint envelope: an object [Schema] wrapping
/// [itemSchema] as a page of results alongside the un-paginated match count.
///
/// The emitted shape is exactly the `{"items": [...], "total": n}` pattern
/// every list endpoint hand-writes today — `items` and `total` both
/// `required`, no additional properties admitted — produced as an ordinary
/// [Schema], not a generic or a code-generated type. [listSchema] composes
/// the same plain `Schema` a hand-written envelope would, so
/// `validate`/`require`/`requireMap` and the OpenAPI walker treat it exactly
/// like one; this is a helper over the canonical WRITING pattern (a judged
/// restraint), not a replacement for it.
///
/// `items` is the current page — bounded by whatever pagination (`?limit`/
/// `?offset` or otherwise) the handler applies. `total` is how many rows
/// match the query across *all* pages, independent of that window, so a
/// client can compute how many pages remain without walking them; it is the
/// total matching count, not the page size — an empty `items` with a
/// positive `total` is a legitimate answer to an offset past the end of the
/// result set.
///
/// The wrapper is named `'${itemSchema.name}List'` and carries [itemSchema]
/// in `deps`, so the OpenAPI walker collects both into `components/schemas`
/// and the `items` array's `$ref` resolves. Because it builds a new `Schema`
/// per call rather than reading a `const`, a `RouteDoc` that embeds
/// `listSchema(itemSchema)` cannot itself be `const` — unlike a hand-written
/// envelope schema, which is declared once as a top-level `const Schema` and
/// referenced everywhere.
Schema listSchema(Schema itemSchema) => Schema(
  '${itemSchema.name}List',
  {
    'type': 'object',
    'required': ['items', 'total'],
    'properties': {
      'items': {
        'type': 'array',
        'items': {r'$ref': '#/components/schemas/${itemSchema.name}'},
      },
      'total': {'type': 'integer'},
    },
    'additionalProperties': false,
  },
  deps: [itemSchema],
);

/// A node in the JSON path to the value currently being validated, carried as a
/// cheap parent-linked chain instead of an eagerly-built `$.a.b[0]` string.
///
/// Every recursion step used to concatenate `'$path.$key'` / `'$path[$i]'` to
/// descend, materializing a path string for *every* node even when the body is
/// fully valid and no violation ever cites it — O(depth²) characters of pure
/// waste on the common path. Descending now allocates one small [_Path] node
/// (O(1), no character copying), and the dotted/indexed string is built by
/// [toString] only where a message is actually emitted (`errors.add`, an
/// authoring [StateError]) — the error path, which is rare. The rendered string
/// is byte-identical to the old concatenation: [root] renders `$`, [key]
/// prepends `.` to its segment, [index] wraps it in `[...]`, so a chain
/// stringifies to exactly the `$.a.b[0]` the old code spelled out.
final class _Path {
  const _Path._(this.parent, this.segment);

  /// The document root, `$`.
  static const _Path root = _Path._(null, r'$');

  final _Path? parent;

  /// This node's own text: `$` at the root, `.key` for a property step, `[i]`
  /// for an array-index step. The delimiter lives in the segment so [toString]
  /// is a plain parent-then-self concatenation.
  final String segment;

  /// A property step: `path.key('city')` renders as `<path>.city`.
  _Path key(String name) => _Path._(this, '.$name');

  /// An array-index step: `path.index(3)` renders as `<path>[3]`.
  _Path index(int i) => _Path._(this, '[$i]');

  @override
  String toString() {
    if (parent == null) return segment;
    final buffer = StringBuffer();
    _write(buffer);
    return buffer.toString();
  }

  void _write(StringBuffer buffer) {
    parent?._write(buffer);
    buffer.write(segment);
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
  _Path path,
  String key,
  String problem,
) {
  throw StateError('schema "$schemaName" at $path: "$key" $problem');
}

void _validate(
  Map<String, Object?> schema,
  Object? value,
  _Path path,
  List<String> errors,
  Map<String, Schema> refs,
  String schemaName,
) {
  _rejectUnenforcedKeywords(schema, path, schemaName);
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
      // fragment. There is no type gate to apply, but any scalar/array value
      // keyword the fragment carries still binds by the instance's own type
      // (JSON Schema evaluates keywords against the instance, not a declared
      // type), so dispatch by what the value actually is.
      switch (value) {
        case String():
          _stringKeywords(schema, value, path, errors, schemaName);
        case num():
          _numberKeywords(schema, value, path, errors, schemaName);
        case List():
          _arrayKeywords(schema, value, path, errors, schemaName);
      }
    case 'object':
      _validateObject(schema, value, path, errors, refs, schemaName);
    case 'array':
      _validateArray(schema, value, path, errors, refs, schemaName);
    case 'string':
      if (value is! String) {
        errors.add('$path: expected string, got ${_typeName(value)}');
      } else {
        _stringKeywords(schema, value, path, errors, schemaName);
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
      } else {
        _numberKeywords(schema, value, path, errors, schemaName);
      }
    case 'number':
      if (value is! num) {
        errors.add('$path: expected number, got ${_typeName(value)}');
      } else {
        _numberKeywords(schema, value, path, errors, schemaName);
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
  _Path path,
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
          path.key(entry.key),
          'properties.${entry.key}',
          'must be an object schema fragment, got ${_typeName(sub)}',
        );
      }
      _validate(sub, v, path.key(entry.key), errors, refs, schemaName);
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
          path.key(entry.key.toString()),
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
  _Path path,
  List<String> errors,
  Map<String, Schema> refs,
  String schemaName,
) {
  if (value is! List) {
    errors.add('$path: expected array, got ${_typeName(value)}');
    return;
  }
  // Array-level keywords bind to the array itself, so they are checked whether
  // or not an individual element also fails below — a too-short array is a
  // distinct fact from a mistyped element.
  _arrayKeywords(schema, value, path, errors, schemaName);
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
    _validate(items, value[i], path.index(i), errors, refs, schemaName);
  }
}

void _validateEnum(
  Map<String, Object?> schema,
  Object? value,
  _Path path,
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
  _Path path,
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

/// Recognized JSON Schema validation keywords that keta deliberately does not
/// enforce. Any of these present in a fragment is authoring damage: it would be
/// emitted into the document as a constraint the boundary silently ignores.
/// (The keywords keta *does* enforce — `type`, `enum`, `required`, `items`,
/// `properties`, `additionalProperties`, `oneOf`/`discriminator`, `$ref`, and
/// the scalar/array value keywords handled by [_stringKeywords],
/// [_numberKeywords], and [_arrayKeywords] — are absent from this set, as are
/// pure annotations, which are not validation keywords at all.)
const _unenforcedValidationKeywords = <String>{
  'const',
  'allOf',
  'anyOf',
  'not',
  'if',
  'then',
  'else',
  'dependentRequired',
  'dependentSchemas',
  'prefixItems',
  'contains',
  'minContains',
  'maxContains',
  'minProperties',
  'maxProperties',
  'patternProperties',
  'propertyNames',
  'unevaluatedItems',
  'unevaluatedProperties',
};

/// Throws a [StateError] (posture (1)) if [schema] declares a validation
/// keyword keta does not enforce — "what you can write takes effect; what
/// doesn't take effect can't be written". Runs before the `$ref`/`oneOf`
/// branches so a stray keyword beside either is caught too.
void _rejectUnenforcedKeywords(
  Map<String, Object?> schema,
  _Path path,
  String schemaName,
) {
  for (final key in schema.keys) {
    if (_unenforcedValidationKeywords.contains(key)) {
      _authoringDefect(
        schemaName,
        path,
        key,
        'is a JSON Schema validation keyword keta does not enforce; a schema '
        'must not declare a constraint the boundary would silently ignore',
      );
    }
  }
}

/// The absolute ceiling, in Unicode code points, on the length of a string the
/// boundary will run a `pattern` regex against. `pattern` has no ReDoS guard of
/// its own — a hostile pattern such as `^(a+)+$` backtracks catastrophically —
/// so its safety rests on the input being length-bounded. The primary bound is
/// the author's own `maxLength`, which gates the regex (see [_stringKeywords]);
/// this constant is the backstop for the schema that carries a `pattern` with
/// no `maxLength`, or a `maxLength` larger than this, so the megabyte-scale body
/// the 1 MiB request cap would otherwise admit can never reach an unguarded
/// regex. A string longer than this is reported as a violation instead of being
/// pattern-matched. 4096 code points is generous for every realistic
/// pattern-validated scalar (emails, UUIDs, slugs, tokens, URLs) yet small
/// enough to keep the regex off megabyte-scale input.
const _patternInputCeiling = 4096;

/// Applies the string value keywords (`minLength`, `maxLength`, `pattern`,
/// `format`) to a string [value]. Length is counted in Unicode code points.
void _stringKeywords(
  Map<String, Object?> schema,
  String value,
  _Path path,
  List<String> errors,
  String schemaName,
) {
  // Counting code points is an O(len) walk of the whole string, but only
  // `minLength`/`maxLength`/`pattern` ever read the count. A string with no
  // length constraint (a plain `type: string`, or one carrying only a
  // `format` annotation) must not pay that walk, so the count is deferred:
  // `late final` computes it at most once, on the first keyword that needs it,
  // and never at all otherwise. Behavior is identical — the same code-point
  // count, just not eagerly materialized.
  late final int length = value.runes.length;
  var maxLengthExceeded = false;
  if (schema.containsKey('minLength')) {
    final min = _nonNegativeIntKeyword(schema, 'minLength', path, schemaName);
    if (length < min) {
      errors.add('$path: string length $length is shorter than minLength $min');
    }
  }
  if (schema.containsKey('maxLength')) {
    final max = _nonNegativeIntKeyword(schema, 'maxLength', path, schemaName);
    if (length > max) {
      errors.add('$path: string length $length exceeds maxLength $max');
      maxLengthExceeded = true;
    }
  }
  if (schema.containsKey('pattern')) {
    final raw = schema['pattern'];
    if (raw is! String) {
      _authoringDefect(
        schemaName,
        path,
        'pattern',
        'must be a string, got ${_typeName(raw)}',
      );
    }
    // Compiled unconditionally (before the length gates below) so an
    // uncompilable pattern — the author's mistake, unreachable by any request —
    // surfaces as an authoring defect regardless of the instance that arrives.
    // The compiled [RegExp] is cached across calls (see [_compilePattern]).
    final regExp = _compilePattern(raw, path, schemaName);
    // The length bound gates the regex. A value that already exceeds the
    // enforced `maxLength` is condemned; also running the author's ECMAScript
    // pattern over it adds nothing but the ReDoS exposure the bound exists to
    // foreclose, so skip the match. (A too-*short* string is cheap to match,
    // so only the maxLength-exceeded case is skipped, not a minLength miss.)
    if (!maxLengthExceeded) {
      if (length > _patternInputCeiling) {
        // Defense in depth for the schema that omits `maxLength` (or set one
        // above the ceiling): the megabyte-scale body the 1 MiB request cap
        // admits must never reach an unguarded regex. The value is reported by
        // length only — echoing a multi-kilobyte string back would be its own
        // abuse.
        errors.add(
          '$path: string length $length exceeds the pattern-validation '
          'ceiling of $_patternInputCeiling code points',
        );
      } else if (!regExp.hasMatch(value)) {
        // Unanchored: a partial match anywhere satisfies `pattern`, per JSON
        // Schema.
        errors.add('$path: "$value" does not match pattern $raw');
      }
    }
  }
  if (schema.containsKey('format')) {
    final raw = schema['format'];
    if (raw is! String) {
      _authoringDefect(
        schemaName,
        path,
        'format',
        'must be a string, got ${_typeName(raw)}',
      );
    }
    // A `null` verdict means the format is not in keta's enforced set — an
    // annotation, passed through untouched (never a violation).
    if (_formatValid(raw, value) == false) {
      errors.add('$path: "$value" is not a valid $raw');
    }
  }
}

/// Compiles a `pattern` string to a [RegExp], memoized in [_patternCache].
/// A `pattern` that does not compile is authoring damage (posture (1)): the
/// [_authoringDefect] fires on the first attempt and — because a failed compile
/// is never cached — on every attempt after, so the defect can never be masked
/// by a later instance slipping past it. `schema.validate` is hot (per validated
/// request), yet `RegExp(raw)` was the one uncached regex construction left in
/// the package (the `format` regexes are top-level finals), rebuilt on every
/// call. Caching it removes that per-request cost.
RegExp _compilePattern(String raw, _Path path, String schemaName) {
  final cached = _patternCache[raw];
  if (cached != null) return cached;
  final RegExp regExp;
  try {
    regExp = RegExp(raw);
  } on FormatException catch (e) {
    _authoringDefect(
      schemaName,
      path,
      'pattern',
      'is not a valid regular expression: ${e.message}',
    );
  }
  return _patternCache[raw] = regExp;
}

/// Compiled-[RegExp] memo for `pattern`, keyed on the raw pattern string. No
/// flags are ever applied, so the string alone fully determines the regex's
/// semantics and is a sound cache key. The cache is deliberately unbounded: a
/// `pattern` originates only from an author's `const Schema` graph, never from a
/// request, so the set of distinct keys is bounded by the code's size, not by
/// anything an attacker can grow — it is code-sized, not attacker-sized.
final Map<String, RegExp> _patternCache = <String, RegExp>{};

/// Applies the numeric value keywords (`minimum`, `maximum`,
/// `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`) to a numeric [value].
void _numberKeywords(
  Map<String, Object?> schema,
  num value,
  _Path path,
  List<String> errors,
  String schemaName,
) {
  if (schema.containsKey('minimum')) {
    final min = _numberKeyword(schema, 'minimum', path, schemaName);
    if (value < min) {
      errors.add('$path: $value is less than minimum $min');
    }
  }
  if (schema.containsKey('maximum')) {
    final max = _numberKeyword(schema, 'maximum', path, schemaName);
    if (value > max) {
      errors.add('$path: $value is greater than maximum $max');
    }
  }
  if (schema.containsKey('exclusiveMinimum')) {
    final min = _numberKeyword(schema, 'exclusiveMinimum', path, schemaName);
    if (value <= min) {
      errors.add('$path: $value is not greater than exclusiveMinimum $min');
    }
  }
  if (schema.containsKey('exclusiveMaximum')) {
    final max = _numberKeyword(schema, 'exclusiveMaximum', path, schemaName);
    if (value >= max) {
      errors.add('$path: $value is not less than exclusiveMaximum $max');
    }
  }
  if (schema.containsKey('multipleOf')) {
    final factor = _numberKeyword(schema, 'multipleOf', path, schemaName);
    if (factor <= 0) {
      _authoringDefect(
        schemaName,
        path,
        'multipleOf',
        'must be greater than zero, got $factor',
      );
    }
    if (!_isMultipleOf(value, factor)) {
      errors.add('$path: $value is not a multiple of $factor');
    }
  }
}

/// Applies the array value keywords (`minItems`, `maxItems`, `uniqueItems`) to
/// a list [value].
void _arrayKeywords(
  Map<String, Object?> schema,
  List<Object?> value,
  _Path path,
  List<String> errors,
  String schemaName,
) {
  if (schema.containsKey('minItems')) {
    final min = _nonNegativeIntKeyword(schema, 'minItems', path, schemaName);
    if (value.length < min) {
      errors.add(
        '$path: array length ${value.length} is shorter than minItems $min',
      );
    }
  }
  var maxItemsExceeded = false;
  if (schema.containsKey('maxItems')) {
    final max = _nonNegativeIntKeyword(schema, 'maxItems', path, schemaName);
    if (value.length > max) {
      errors.add('$path: array length ${value.length} exceeds maxItems $max');
      maxItemsExceeded = true;
    }
  }
  if (schema.containsKey('uniqueItems')) {
    final raw = schema['uniqueItems'];
    if (raw is! bool) {
      // A malformed `uniqueItems` is authoring damage regardless of the
      // instance, so this check runs before the maxItems gate below.
      _authoringDefect(
        schemaName,
        path,
        'uniqueItems',
        'must be a boolean, got ${_typeName(raw)}',
      );
    }
    if (raw && !maxItemsExceeded) {
      if (value.length > _uniqueItemsCeiling) {
        // Defense in depth for the schema that omits `maxItems` (or set one
        // above the ceiling): the ~900 KB array the 1 MiB request cap admits
        // must never reach the O(n²) uniqueness scan. Reported by length only
        // — the same posture the pattern ceiling takes. Unlike a string, an
        // array can be legitimately large, so this ceiling sits well above the
        // pattern one; an endpoint that genuinely needs uniqueness over more
        // items must declare a `maxItems` (which gates the scan itself).
        errors.add(
          '$path: array length ${value.length} exceeds the '
          'uniqueItems-validation ceiling of $_uniqueItemsCeiling items',
        );
      } else {
        // Deep pairwise equality is O(n²) and is needed only for *composite*
        // elements (Map/List), whose equality is structural. Scalars
        // (String/num/bool/null) carry value semantics, so a single O(n)
        // [HashSet] pass detects a duplicate among them — and it agrees with
        // [_jsonEquals] exactly, because [HashSet] uses Dart's own `==`/
        // `hashCode` and those match `_jsonEquals` on scalars: notably
        // `1 == 1.0` is `true` *and* `1.hashCode == 1.0.hashCode`, so an int
        // collides with its zero-fraction double twin here just as it does
        // under `_jsonEquals`. (The lone divergence — two *identical* NaN
        // instances, which `==` treats as distinct but `_jsonEquals` catches
        // via its `identical` fast path — cannot arise from decoded JSON, which
        // has no NaN, so it is unreachable at this boundary.)
        //
        // The pass walks the array once: on the first *composite* element, or
        // the first scalar the set proves is a repeat, it falls back to the
        // existing pairwise scan (the simplest correct composition) — which is
        // what emits the violation. So the common case, a valid all-scalar
        // array, pays one linear pass and stops; every case that must report a
        // collision (or deep-compare composites) still runs the pairwise scan
        // and its byte-identical message and pair indices. The `maxItems` gate
        // above still bounds the pairwise cost when it does run.
        var needsPairwise = false;
        final seen = HashSet<Object?>();
        for (final element in value) {
          if (element is Map || element is List || !seen.add(element)) {
            needsPairwise = true;
            break;
          }
        }
        if (needsPairwise) {
          // One violation is enough to condemn the array, so the first
          // colliding pair ends the scan.
          outer:
          for (var i = 0; i < value.length; i++) {
            for (var j = i + 1; j < value.length; j++) {
              if (_jsonEquals(value[i], value[j])) {
                errors.add(
                  '$path: array items at [$i] and [$j] are equal '
                  '(uniqueItems)',
                );
                break outer;
              }
            }
          }
        }
      }
    }
  }
}

/// The hard ceiling on how many items the O(n²) `uniqueItems` scan will ever
/// examine when the schema declares no `maxItems`, or a `maxItems` larger than
/// this. An array longer than this is reported as a violation instead of being
/// scanned, so the ~900 KB array the 1 MiB request cap would otherwise admit can
/// never reach the quadratic scan. Set well above [_patternInputCeiling]: unlike
/// a pattern-validated scalar, an array can be legitimately large, so an
/// endpoint needing uniqueness over more items declares an explicit `maxItems`
/// (which gates the scan on its own) rather than leaning on this backstop.
const _uniqueItemsCeiling = 8192;

/// Reads [key] from [schema] as a non-negative integer, or throws the authoring
/// [StateError] a malformed length/count bound gets (posture (1)).
int _nonNegativeIntKeyword(
  Map<String, Object?> schema,
  String key,
  _Path path,
  String schemaName,
) {
  final raw = schema[key];
  if (raw is! int) {
    _authoringDefect(
      schemaName,
      path,
      key,
      'must be a non-negative integer, got ${_typeName(raw)}',
    );
  }
  if (raw < 0) {
    _authoringDefect(
      schemaName,
      path,
      key,
      'must be a non-negative integer, got $raw',
    );
  }
  return raw;
}

/// Reads [key] from [schema] as a number, or throws the authoring [StateError]
/// a malformed numeric bound gets (posture (1)).
num _numberKeyword(
  Map<String, Object?> schema,
  String key,
  _Path path,
  String schemaName,
) {
  final raw = schema[key];
  if (raw is! num) {
    _authoringDefect(
      schemaName,
      path,
      key,
      'must be a number, got ${_typeName(raw)}',
    );
  }
  return raw;
}

/// Whether [value] is an integer multiple of [factor]. Integer operands are
/// exact; fractional operands use a small relative tolerance so binary
/// floating-point error (`0.3 / 0.1 == 2.9999999999999996`) does not reject a
/// genuine multiple, while a real non-multiple (`0.35 / 0.1`) still fails.
bool _isMultipleOf(num value, num factor) {
  if (value is int && factor is int) return value % factor == 0;
  final quotient = value / factor;
  final nearest = quotient.roundToDouble();
  final scale = quotient.abs() < 1 ? 1.0 : quotient.abs();
  return (quotient - nearest).abs() <= 1e-9 * scale;
}

/// The enforced-format verdict: `true`/`false` for a format in keta's crisp
/// set (`date-time`, `date`, `uuid`), `null` for any other format — which is an
/// annotation, not a constraint, and so never a violation.
bool? _formatValid(String format, String value) => switch (format) {
  'date-time' => _isRfc3339DateTime(value),
  'date' => _isRfc3339FullDate(value),
  'uuid' => _uuidPattern.hasMatch(value),
  _ => null,
};

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

final _fullDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// RFC 3339 `full-date` (`YYYY-MM-DD`), rejecting impossible calendar dates
/// (a round-trip through [DateTime.utc] catches overflow like `2026-02-30`).
bool _isRfc3339FullDate(String value) {
  final match = _fullDatePattern.firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  if (month < 1 || month > 12 || day < 1 || day > 31) return false;
  final date = DateTime.utc(year, month, day);
  return date.year == year && date.month == month && date.day == day;
}

final _dateTimePattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})[Tt]'
  r'(\d{2}):(\d{2}):(\d{2})(\.\d+)?'
  r'([Zz]|[+-]\d{2}:\d{2})$',
);

/// RFC 3339 `date-time`: a valid `full-date`, a `T` (or `t`) separator, a
/// `HH:MM:SS` time (with optional fractional seconds), and a `Z`/`z` or numeric
/// `±HH:MM` offset. A leap second (`:60`) is admitted, as the grammar allows.
bool _isRfc3339DateTime(String value) {
  final match = _dateTimePattern.firstMatch(value);
  if (match == null) return false;
  if (!_isRfc3339FullDate('${match[1]}-${match[2]}-${match[3]}')) return false;
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  if (hour > 23 || minute > 59 || second > 60) return false;
  final offset = match[8]!;
  if (offset != 'Z' && offset != 'z') {
    final offsetHour = int.parse(offset.substring(1, 3));
    final offsetMinute = int.parse(offset.substring(4, 6));
    if (offsetHour > 23 || offsetMinute > 59) return false;
  }
  return true;
}

/// Deep structural equality over JSON-shaped values, used by `uniqueItems` so
/// two equal (but non-identical) nested objects or arrays count as duplicates.
bool _jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
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
