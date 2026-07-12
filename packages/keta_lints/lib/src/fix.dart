library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'dart_literal.dart';

/// Applies the canonical-form repair to [source].
///
/// For every DTO-shaped class it regenerates the canonical members — `fromJson`,
/// `toJson`, and the matching `Schema` constant — **whole**, from the desired
/// state (the field set), and atomically replaces each member's source range.
/// Whole-member regeneration (rather than per-field surgery) makes the edits
/// non-overlapping by construction, so removing several fields, renaming the
/// sole field, or repairing a half-missing pair can't corrupt the source.
///
/// A leading `///` doc comment on a regenerated member is preserved. The
/// `Schema` constant keeps every existing per-property definition (enums,
/// formats) verbatim and re-derives `$ref`/`deps` from one model. A class whose
/// `toJson` is not a recognizable canonical map literal is treated as
/// hand-modified and left untouched.
String applyCanonicalFix(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;

  final schemas = _schemaInitializers(unit);
  final enums = <String, List<String>>{};
  // A class is a DTO by signal: it has a Schema constant, a fromJson factory,
  // or a toJson method — never by the shape of its fields (which is a guess).
  final dtoNames = <String>{...schemas.keys};
  for (final declaration in unit.declarations) {
    if (declaration is EnumDeclaration) {
      enums[declaration.namePart.typeName.lexeme] = declaration.body.constants
          .map((c) => c.name.lexeme)
          .toList();
    } else if (declaration is ClassDeclaration && _hasMapper(declaration)) {
      dtoNames.add(declaration.namePart.typeName.lexeme);
    }
  }
  final resolver = _TypeResolver(enums, dtoNames);

  final edits = <_Edit>[];
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration) {
      _fixClass(declaration, resolver, dtoNames, schemas, source, edits);
    }
  }
  return _applyEdits(source, edits);
}

bool _hasMapper(ClassDeclaration node) {
  for (final member in node.body.members) {
    if (member is ConstructorDeclaration &&
        member.factoryKeyword != null &&
        member.name?.lexeme == 'fromJson') {
      return true;
    }
    if (member is MethodDeclaration && member.name.lexeme == 'toJson') {
      return true;
    }
  }
  return false;
}

class _Edit {
  _Edit(this.start, this.end, this.replacement);
  final int start;
  final int end;
  final String replacement;
}

String _applyEdits(String source, List<_Edit> edits) {
  edits.sort((a, b) => b.start.compareTo(a.start));
  // Invariant: edits never overlap (whole-member/whole-initializer ranges).
  for (var i = 0; i + 1 < edits.length; i++) {
    if (edits[i].start < edits[i + 1].end) {
      throw StateError('overlapping canonical fix edits');
    }
  }
  var result = source;
  for (final edit in edits) {
    result = result.replaceRange(edit.start, edit.end, edit.replacement);
  }
  return result;
}

void _fixClass(
  ClassDeclaration node,
  _TypeResolver resolver,
  Set<String> dtoNames,
  Map<String, Expression> schemas,
  String source,
  List<_Edit> edits,
) {
  final className = node.namePart.typeName.lexeme;
  // Only touch classes with a canonical signal, and never an abstract/sealed
  // one (a factory can't instantiate it).
  if (!dtoNames.contains(className)) return;
  if (node.abstractKeyword != null || node.sealedKeyword != null) return;

  final fields = <_Field>[];
  ConstructorDeclaration? genCtor;
  var unresolvable = false;
  ConstructorDeclaration? fromJson;
  MethodDeclaration? toJson;

  for (final member in node.body.members) {
    if (member is FieldDeclaration &&
        !member.isStatic &&
        member.fields.isFinal) {
      // Skip fields with initializers / late — not constructor parameters.
      for (final v in member.fields.variables) {
        if (v.initializer == null) {
          final type = resolver.resolve(member.fields.type);
          if (type == null) {
            unresolvable = true; // a field type outside the canonical subset
          } else {
            fields.add(_Field(v.name.lexeme, type));
          }
        }
      }
    } else if (member is ConstructorDeclaration) {
      if (member.factoryKeyword == null) {
        genCtor = member;
      } else if (member.name?.lexeme == 'fromJson') {
        fromJson = member;
      }
    } else if (member is MethodDeclaration && member.name.lexeme == 'toJson') {
      toJson = member;
    }
  }
  // A field type we can't resolve within the file (a cross-file enum, or a
  // non-canonical type like DateTime) is out of scope — regenerating would
  // guess, so leave the class untouched.
  if (unresolvable || fields.isEmpty || genCtor == null) return;
  // The generated fromJson calls the ctor with NAMED args, so the class must
  // have a canonical named-parameter ctor covering every field. A positional
  // (or otherwise non-matching) ctor is left untouched rather than miscompiled.
  final ctorNamed = {
    for (final p in genCtor.parameters.parameters)
      if (p.isNamed) p.name?.lexeme,
  };
  if (!fields.every((f) => ctorNamed.contains(f.name))) return;
  if (toJson != null && !_isCanonicalMap(toJson)) return; // hand-modified.

  final fieldNames = {for (final f in fields) f.name};
  final schema = schemas[className];
  final mapperDrifted =
      fromJson == null ||
      toJson == null ||
      !_setEquals(_toJsonKeys(toJson)!, fieldNames);
  final schemaDrifted =
      schema != null && !_setEquals(_schemaPropertyNames(schema), fieldNames);
  if (!mapperDrifted && !schemaDrifted) return; // already canonical.

  final insertions = <String>[];
  void member(Declaration? existing, String generated) {
    if (existing == null) {
      insertions.add(generated);
    } else {
      final start = existing.firstTokenAfterCommentAndMetadata.offset;
      edits.add(_Edit(start, existing.end, generated.trimLeft()));
    }
  }

  member(fromJson, _fromJsonSource(className, fields));
  member(toJson, _toJsonSource(fields));
  if (insertions.isNotEmpty) {
    final at = node.body.end - 1; // before the class's closing brace
    edits.add(_Edit(at, at, '\n${insertions.join('\n\n')}\n'));
  }
  if (schema != null) {
    edits.add(
      _Edit(
        schema.offset,
        schema.end,
        _schemaSource(className, fields, schema, source),
      ),
    );
  }
}

// --- schema constant ------------------------------------------------------

Map<String, Expression> _schemaInitializers(CompilationUnit unit) {
  final result = <String, Expression>{};
  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration) continue;
    for (final variable in declaration.variables.variables) {
      final init = variable.initializer;
      final (name, isSchema) = switch (init) {
        InstanceCreationExpression(
          :final constructorName,
          :final argumentList,
        ) =>
          (
            _firstStringArg(argumentList),
            constructorName.type.name.lexeme == 'Schema',
          ),
        MethodInvocation(:final methodName, :final argumentList) => (
          _firstStringArg(argumentList),
          methodName.name == 'Schema',
        ),
        _ => (null, false),
      };
      if (isSchema && name != null && init != null) result[name] = init;
    }
  }
  return result;
}

String? _firstStringArg(ArgumentList args) {
  final first = args.arguments.isEmpty ? null : args.arguments.first;
  return first is SimpleStringLiteral ? first.value : null;
}

SetOrMapLiteral? _schemaMap(Expression init) {
  final args = switch (init) {
    InstanceCreationExpression(:final argumentList) => argumentList.arguments,
    MethodInvocation(:final argumentList) => argumentList.arguments,
    _ => null,
  };
  if (args == null || args.length < 2) return null;
  final map = args[1];
  return map is SetOrMapLiteral ? map : null;
}

SetOrMapLiteral? _propertiesLiteral(SetOrMapLiteral map) {
  for (final element in map.elements) {
    if (element is MapLiteralEntry &&
        element.key is SimpleStringLiteral &&
        (element.key as SimpleStringLiteral).value == 'properties' &&
        element.value is SetOrMapLiteral) {
      return element.value as SetOrMapLiteral;
    }
  }
  return null;
}

Set<String> _schemaPropertyNames(Expression init) {
  final map = _schemaMap(init);
  final props = map == null ? null : _propertiesLiteral(map);
  if (props == null) return const {};
  return {
    for (final e in props.elements)
      if (e is MapLiteralEntry && e.key is SimpleStringLiteral)
        (e.key as SimpleStringLiteral).value,
  };
}

/// Regenerates the whole `Schema(...)` initializer, preserving each existing
/// property definition verbatim (so enums/formats survive), preserving any
/// other top-level schema key (`description`, `additionalProperties`, …), and
/// re-deriving `required` and `deps` from the field model.
String _schemaSource(
  String className,
  List<_Field> fields,
  Expression init,
  String source,
) {
  final map = _schemaMap(init);
  final props = map == null ? null : _propertiesLiteral(map);
  final existing = <String, String>{};
  if (props != null) {
    for (final e in props.elements) {
      if (e is MapLiteralEntry && e.key is SimpleStringLiteral) {
        existing[(e.key as SimpleStringLiteral).value] = source.substring(
          e.value.offset,
          e.value.end,
        );
      }
    }
  }
  // Preserve top-level keys the regeneration doesn't own (so a `description` or
  // `additionalProperties` is not silently dropped), verbatim and in order.
  final extras = <String>[];
  const owned = {'type', 'required', 'properties'};
  if (map != null) {
    for (final e in map.elements) {
      if (e is MapLiteralEntry && e.key is SimpleStringLiteral) {
        final key = (e.key as SimpleStringLiteral).value;
        if (owned.contains(key)) continue;
        extras.add(source.substring(e.key.offset, e.value.end));
      }
    }
  }

  final properties = [
    for (final f in fields)
      "'${f._keyLiteral}': ${existing[f.name] ?? dartLiteral(f.type.schemaJson())}",
  ];
  final required = [
    for (final f in fields)
      if (!f.type.nullable) "'${f._keyLiteral}'",
  ];
  final deps = <String>{};
  for (final f in fields) {
    f.type.collectDtoRefs(deps);
  }

  final buffer = StringBuffer("Schema('$className', {'type': 'object'");
  if (required.isNotEmpty) {
    buffer.write(", 'required': [${required.join(', ')}]");
  }
  buffer.write(", 'properties': {${properties.join(', ')}}");
  for (final extra in extras) {
    buffer.write(', $extra');
  }
  buffer.write('}');
  final depList = deps.toList()..sort();
  if (depList.isNotEmpty) {
    buffer.write(
      ', deps: [${depList.map((d) => '${_lowerFirst(d)}Schema').join(', ')}]',
    );
  }
  buffer.write(')');
  return buffer.toString();
}

bool _isCanonicalMap(MethodDeclaration toJson) => _returnedMap(toJson) != null;

Set<String>? _toJsonKeys(MethodDeclaration toJson) {
  final returned = _returnedMap(toJson);
  if (returned == null) return null;
  final keys = <String>{};
  void collect(Iterable<CollectionElement> elements) {
    for (final element in elements) {
      switch (element) {
        case MapLiteralEntry(:final key) when key is SimpleStringLiteral:
          keys.add(key.value);
        case IfElement():
          collect([element.thenElement]);
          if (element.elseElement != null) collect([element.elseElement!]);
        default:
          break;
      }
    }
  }

  collect(returned.elements);
  return keys;
}

SetOrMapLiteral? _returnedMap(MethodDeclaration toJson) {
  final body = toJson.body;
  Expression? returned;
  if (body is ExpressionFunctionBody) {
    returned = body.expression;
  } else if (body is BlockFunctionBody) {
    for (final statement in body.block.statements) {
      if (statement is ReturnStatement) returned = statement.expression;
    }
  }
  return returned is SetOrMapLiteral ? returned : null;
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

// --- mapper generation ----------------------------------------------------

String _fromJsonSource(String className, List<_Field> fields) {
  final buffer = StringBuffer(
    '  factory $className.fromJson(Map<String, Object?> json) => $className(\n',
  );
  for (final f in fields) {
    buffer.writeln('        ${f.name}: ${f.fromJsonExpr()},');
  }
  buffer.write('      );');
  return buffer.toString();
}

String _toJsonSource(List<_Field> fields) {
  final buffer = StringBuffer('  Map<String, Object?> toJson() => {\n');
  for (final f in fields) {
    buffer.writeln(f.toJsonEntry());
  }
  buffer.write('      };');
  return buffer.toString();
}

// --- field / type model ---------------------------------------------------

class _Field {
  _Field(this.name, this.type);
  final String name;
  final _FieldType type;

  /// The field name escaped for embedding inside a generated single-quoted
  /// string literal — a name containing `$`, `'`, or `\` (all legal in a Dart
  /// identifier) must not become interpolation or an unterminated literal.
  String get _keyLiteral => name
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');

  String fromJsonExpr() {
    final t = type;
    final key = _keyLiteral;
    if (t is _Prim && t.dart != 'double') {
      return t.nullable
          ? "json['$key'] as ${t.dart}?"
          : "json['$key'] as ${t.dart}";
    }
    final expr = t.fromJson("json['$key']");
    return t.nullable ? "json['$key'] == null ? null : $expr" : expr;
  }

  String toJsonEntry() {
    final value = type.toJson(name, nullable: type.nullable);
    final key = _keyLiteral;
    if (!type.nullable) return "        '$key': $value,";
    return "        if ($name != null) '$key': $value,";
  }
}

sealed class _FieldType {
  const _FieldType(this.nullable);
  final bool nullable;

  String fromJson(String access);
  String toJson(String name, {required bool nullable});
  Object? schemaJson();
  void collectDtoRefs(Set<String> into) {}
}

class _Prim extends _FieldType {
  const _Prim(this.dart, super.nullable);
  final String dart;

  @override
  String fromJson(String access) =>
      dart == 'double' ? '($access as num).toDouble()' : '$access as $dart';
  @override
  String toJson(String name, {required bool nullable}) => name;
  @override
  Object? schemaJson() => {
    'type': switch (dart) {
      'int' => 'integer',
      'double' => 'number',
      'bool' => 'boolean',
      _ => 'string',
    },
  };
}

class _EnumType extends _FieldType {
  const _EnumType(this.name, this.values, super.nullable);
  final String name;
  final List<String>? values;

  @override
  String fromJson(String access) => '$name.values.byName($access as String)';
  @override
  String toJson(String field, {required bool nullable}) =>
      nullable ? '$field!.name' : '$field.name';
  @override
  Object? schemaJson() => {
    'type': 'string',
    if (values != null) 'enum': values,
  };
}

class _DtoType extends _FieldType {
  const _DtoType(this.name, super.nullable);
  final String name;

  @override
  String fromJson(String access) =>
      '$name.fromJson($access as Map<String, Object?>)';
  @override
  String toJson(String field, {required bool nullable}) =>
      nullable ? '$field!.toJson()' : '$field.toJson()';
  @override
  Object? schemaJson() => {r'$ref': '#/components/schemas/$name'};
  @override
  void collectDtoRefs(Set<String> into) => into.add(name);
}

class _ListType extends _FieldType {
  const _ListType(this.item, super.nullable);
  final _FieldType item;

  @override
  String fromJson(String access) => switch (item) {
    _Prim(dart: 'double') =>
      '($access as List).map((e) => (e as num).toDouble()).toList()',
    _Prim(:final dart) => '($access as List).cast<$dart>()',
    _EnumType(:final name) =>
      '($access as List).map((e) => $name.values.byName(e as String)).toList()',
    _DtoType(:final name) =>
      '($access as List).map((e) => $name.fromJson(e as Map<String, Object?>)).toList()',
    _ => '$access as List',
  };
  @override
  String toJson(String field, {required bool nullable}) {
    final f = nullable ? '$field!' : field;
    return switch (item) {
      _Prim() => field,
      _EnumType() => '$f.map((e) => e.name).toList()',
      _DtoType() => '$f.map((e) => e.toJson()).toList()',
      _ => field,
    };
  }

  @override
  Object? schemaJson() => {'type': 'array', 'items': item.schemaJson()};
  @override
  void collectDtoRefs(Set<String> into) => item.collectDtoRefs(into);
}

class _MapType extends _FieldType {
  const _MapType(this.value, super.nullable);
  final _FieldType value;

  @override
  String fromJson(String access) => switch (value) {
    _Prim(dart: 'double') =>
      '($access as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()))',
    _Prim(:final dart) => '($access as Map).cast<String, $dart>()',
    _EnumType(:final name) =>
      '($access as Map).map((k, v) => MapEntry(k as String, $name.values.byName(v as String)))',
    _DtoType(:final name) =>
      '($access as Map).map((k, v) => MapEntry(k as String, $name.fromJson(v as Map<String, Object?>)))',
    _ => '($access as Map).cast<String, Object?>()',
  };
  @override
  String toJson(String field, {required bool nullable}) {
    final f = nullable ? '$field!' : field;
    return switch (value) {
      _Prim() => field,
      _EnumType() => '$f.map((k, v) => MapEntry(k, v.name))',
      _DtoType() => '$f.map((k, v) => MapEntry(k, v.toJson()))',
      _ => field,
    };
  }

  @override
  Object? schemaJson() => {
    'type': 'object',
    'additionalProperties': value.schemaJson(),
  };
  @override
  void collectDtoRefs(Set<String> into) => value.collectDtoRefs(into);
}

class _TypeResolver {
  _TypeResolver(this.enums, this.dtoNames);
  final Map<String, List<String>> enums;
  final Set<String> dtoNames;

  /// Resolves a field's type within the canonical subset, or null when it can't
  /// be resolved from this file (a cross-file enum, or a non-canonical type).
  _FieldType? resolve(TypeAnnotation? annotation) =>
      _resolveString(annotation?.toSource() ?? 'Object?');

  _FieldType? _resolveString(String raw) {
    final nullable = raw.endsWith('?');
    final base = nullable
        ? raw.substring(0, raw.length - 1).trim()
        : raw.trim();
    if (base.startsWith('List<') && base.endsWith('>')) {
      final item = _resolveString(base.substring(5, base.length - 1).trim());
      // Nested collections and nullable elements are outside the canonical
      // subset (the generated mappers can't express them) — leave untouched.
      if (item == null ||
          item.nullable ||
          item is _ListType ||
          item is _MapType) {
        return null;
      }
      return _ListType(item, nullable);
    }
    if (base.startsWith('Map<') && base.endsWith('>')) {
      final inner = base.substring(4, base.length - 1);
      final comma = inner.indexOf(',');
      if (comma > 0 && inner.substring(0, comma).trim() == 'String') {
        final value = _resolveString(inner.substring(comma + 1).trim());
        if (value == null ||
            value.nullable ||
            value is _ListType ||
            value is _MapType) {
          return null;
        }
        return _MapType(value, nullable);
      }
      return null;
    }
    switch (base) {
      case 'String':
      case 'int':
      case 'double':
      case 'bool':
        return _Prim(base, nullable);
    }
    if (enums.containsKey(base)) return _EnumType(base, enums[base], nullable);
    if (dtoNames.contains(base)) return _DtoType(base, nullable);
    return null; // unknown/cross-file/non-canonical
  }
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';
