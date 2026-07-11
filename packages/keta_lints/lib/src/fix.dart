library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'dart_literal.dart';

/// Applies the canonical-form repair to [source]: for every DTO-shaped class
/// (final fields + a generative constructor) it materializes a missing
/// `fromJson`/`toJson`, reconciles a drifted pair to the field set, and updates
/// the matching `Schema` constant so OpenAPI reflects the change — all headless.
///
/// A class whose existing `toJson` is not a recognizable canonical map literal
/// is treated as hand-modified and left untouched.
String applyCanonicalFix(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;

  final enums = <String, List<String>>{};
  final classes = <String>{};
  for (final declaration in unit.declarations) {
    if (declaration is EnumDeclaration) {
      enums[declaration.namePart.typeName.lexeme] =
          declaration.body.constants.map((c) => c.name.lexeme).toList();
    } else if (declaration is ClassDeclaration) {
      classes.add(declaration.namePart.typeName.lexeme);
    }
  }
  final resolver = _TypeResolver(enums, classes);
  final schemaInitializers = _schemaInitializers(unit);

  final edits = <_Edit>[];
  for (final declaration in unit.declarations) {
    if (declaration is! ClassDeclaration) continue;
    _fixClass(declaration, resolver, schemaInitializers, edits);
  }
  return _applyEdits(source, edits);
}

class _Edit {
  final int start;
  final int end;
  final String replacement;

  _Edit(this.start, this.end, this.replacement);
}

String _applyEdits(String source, List<_Edit> edits) {
  edits.sort((a, b) => b.start.compareTo(a.start));
  var result = source;
  for (final edit in edits) {
    result = result.replaceRange(edit.start, edit.end, edit.replacement);
  }
  return result;
}

void _fixClass(ClassDeclaration node, _TypeResolver resolver,
    Map<String, Expression> schemaInitializers, List<_Edit> edits) {
  final className = node.namePart.typeName.lexeme;
  final fields = <_Field>[];
  var hasGenerativeCtor = false;
  ConstructorDeclaration? fromJson;
  MethodDeclaration? toJson;

  for (final member in node.body.members) {
    if (member is FieldDeclaration && !member.isStatic && member.fields.isFinal) {
      final type = member.fields.type;
      for (final v in member.fields.variables) {
        fields.add(_Field(v.name.lexeme, resolver.resolve(type)));
      }
    } else if (member is ConstructorDeclaration) {
      if (member.factoryKeyword == null) {
        hasGenerativeCtor = true;
      } else if (member.name?.lexeme == 'fromJson') {
        fromJson = member;
      }
    } else if (member is MethodDeclaration && member.name.lexeme == 'toJson') {
      toJson = member;
    }
  }
  if (fields.isEmpty || !hasGenerativeCtor) return;

  // A recognizable-but-drifted (or absent) pair is repairable; an
  // unrecognizable toJson is hand-modified and left alone.
  if (toJson != null && !_isCanonicalMap(toJson)) return;

  final newFromJson = _fromJsonSource(className, fields);
  final newToJson = _toJsonSource(fields);

  if (fromJson == null && toJson == null) {
    final insertAt = node.body.end - 1; // just before the closing brace
    edits.add(_Edit(insertAt, insertAt, '\n$newFromJson\n\n$newToJson\n'));
  } else {
    if (fromJson != null) {
      edits.add(_Edit(fromJson.offset, fromJson.end, newFromJson.trimLeft()));
    }
    if (toJson != null) {
      edits.add(_Edit(toJson.offset, toJson.end, newToJson.trimLeft()));
    }
  }

  final schema = schemaInitializers[className];
  if (schema != null) {
    _schemaEdits(schema, fields, edits);
  }
}

/// Reconciles the `Schema` map to [fields] surgically: it inserts properties
/// for new fields and removes properties for deleted ones, leaving every
/// existing property definition (enums, formats, descriptions) untouched, so a
/// repair never destroys a hand-refined schema.
void _schemaEdits(
    Expression init, List<_Field> fields, List<_Edit> edits) {
  final args = switch (init) {
    InstanceCreationExpression(:final argumentList) => argumentList.arguments,
    MethodInvocation(:final argumentList) => argumentList.arguments,
    _ => null,
  };
  if (args == null) return;
  final mapArg = args.length >= 2 ? args[1] : null;
  if (mapArg is! SetOrMapLiteral) return;

  SetOrMapLiteral? properties;
  ListLiteral? required;
  for (final element in mapArg.elements) {
    if (element is MapLiteralEntry && element.key is SimpleStringLiteral) {
      final key = (element.key as SimpleStringLiteral).value;
      final value = element.value;
      if (key == 'properties' && value is SetOrMapLiteral) properties = value;
      if (key == 'required' && value is ListLiteral) required = value;
    }
  }
  if (properties == null) return; // not a canonical schema shape.

  final fieldNames = {for (final f in fields) f.name};
  final existing = <String, MapLiteralEntry>{};
  for (final element in properties.elements) {
    if (element is MapLiteralEntry && element.key is SimpleStringLiteral) {
      existing[(element.key as SimpleStringLiteral).value] = element;
    }
  }

  final additions = [
    for (final f in fields)
      if (!existing.containsKey(f.name))
        "'${f.name}': ${dartLiteral(f.type.schemaJson())}",
  ];
  _insertInto(properties, additions, edits);
  for (final entry in existing.entries) {
    if (!fieldNames.contains(entry.key)) {
      edits.add(_removeElement(properties.elements, entry.value));
    }
  }

  if (required != null) {
    final existingRequired = <String, SimpleStringLiteral>{
      for (final e in required.elements)
        if (e is SimpleStringLiteral) e.value: e,
    };
    final desired = {for (final f in fields) if (!f.type.nullable) f.name};
    _insertInto(
      required,
      [for (final f in fields) if (!f.type.nullable && !existingRequired.containsKey(f.name)) "'${f.name}'"],
      edits,
    );
    for (final e in existingRequired.entries) {
      if (!desired.contains(e.key)) {
        edits.add(_removeElement(required.elements, e.value));
      }
    }
  }
}

/// Inserts [additions] into a list/map literal after its last element (so a
/// trailing comma, if any, stays valid) or, when empty, before its bracket.
void _insertInto(
    TypedLiteral literal, List<String> additions, List<_Edit> edits) {
  if (additions.isEmpty) return;
  final elements = literal is SetOrMapLiteral
      ? literal.elements
      : (literal as ListLiteral).elements;
  if (elements.isEmpty) {
    final at = literal.end - 1;
    edits.add(_Edit(at, at, additions.join(', ')));
  } else {
    final at = elements.last.end;
    edits.add(_Edit(at, at, ', ${additions.join(', ')}'));
  }
}

/// Removes [node] from a comma-separated literal, taking a trailing comma when
/// there's a following element, otherwise a leading one.
_Edit _removeElement(List<AstNode> elements, AstNode node) {
  final index = elements.indexOf(node);
  if (index + 1 < elements.length) {
    return _Edit(node.offset, elements[index + 1].offset, '');
  }
  if (index > 0) {
    return _Edit(elements[index - 1].end, node.end, '');
  }
  return _Edit(node.offset, node.end, '');
}

/// Top-level `Schema('Name', ...)` initializers, keyed by the schema name.
Map<String, Expression> _schemaInitializers(CompilationUnit unit) {
  final result = <String, Expression>{};
  for (final declaration in unit.declarations) {
    if (declaration is! TopLevelVariableDeclaration) continue;
    for (final variable in declaration.variables.variables) {
      final init = variable.initializer;
      final (name, isSchema) = switch (init) {
        InstanceCreationExpression(:final constructorName, :final argumentList) =>
          (_firstStringArg(argumentList), constructorName.type.name.lexeme == 'Schema'),
        MethodInvocation(:final methodName, :final argumentList) =>
          (_firstStringArg(argumentList), methodName.name == 'Schema'),
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

bool _isCanonicalMap(MethodDeclaration toJson) {
  final body = toJson.body;
  Expression? returned;
  if (body is ExpressionFunctionBody) {
    returned = body.expression;
  } else if (body is BlockFunctionBody) {
    for (final statement in body.block.statements) {
      if (statement is ReturnStatement) returned = statement.expression;
    }
  }
  return returned is SetOrMapLiteral;
}

// --- mapper generation ----------------------------------------------------

String _fromJsonSource(String className, List<_Field> fields) {
  final buffer = StringBuffer(
      '  factory $className.fromJson(Map<String, Object?> json) => $className(\n');
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
  final String name;
  final _FieldType type;

  _Field(this.name, this.type);

  String fromJsonExpr() {
    final expr = type.fromJson("json['$name']");
    if (!type.nullable) return expr;
    if (type is _Prim && (type as _Prim).dart != 'double') {
      return "json['$name'] as ${(type as _Prim).dart}?";
    }
    return "json['$name'] == null ? null : $expr";
  }

  String toJsonEntry() {
    final value = type.toJson(name, nullable: type.nullable);
    if (!type.nullable) return "        '$name': $value,";
    return "        if ($name != null) '$name': $value,";
  }
}

sealed class _FieldType {
  final bool nullable;
  const _FieldType(this.nullable);

  String fromJson(String access);
  String toJson(String name, {required bool nullable});
  Object? schemaJson();
  void collectDtoRefs(Set<String> into) {}
}

class _Prim extends _FieldType {
  final String dart; // String | int | double | bool
  const _Prim(this.dart, super.nullable);

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
  final String name;
  final List<String>? values;
  const _EnumType(this.name, this.values, super.nullable);

  @override
  String fromJson(String access) => '$name.values.byName($access as String)';
  @override
  String toJson(String field, {required bool nullable}) =>
      nullable ? '$field!.name' : '$field.name';
  @override
  Object? schemaJson() =>
      {'type': 'string', if (values != null) 'enum': values};
}

class _DtoType extends _FieldType {
  final String name;
  const _DtoType(this.name, super.nullable);

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
  final _FieldType item;
  const _ListType(this.item, super.nullable);

  @override
  String fromJson(String access) => switch (item) {
        _Prim(dart: 'double') =>
          '($access as List).map((e) => (e as num).toDouble()).toList()',
        _Prim(:final dart) => '($access as List).cast<$dart>()',
        _EnumType(:final name) =>
          '($access as List).map((e) => $name.values.byName(e as String)).toList()',
        _DtoType(:final name) =>
          '($access as List).map((e) => $name.fromJson(e as Map<String, Object?>)).toList()',
        _ListType() => '$access as List',
      };
  @override
  String toJson(String field, {required bool nullable}) {
    final f = nullable ? '$field!' : field;
    return switch (item) {
      _Prim() => field,
      _EnumType() => '$f.map((e) => e.name).toList()',
      _DtoType() => '$f.map((e) => e.toJson()).toList()',
      _ListType() => field,
    };
  }

  @override
  Object? schemaJson() => {'type': 'array', 'items': item.schemaJson()};
  @override
  void collectDtoRefs(Set<String> into) => item.collectDtoRefs(into);
}

class _TypeResolver {
  final Map<String, List<String>> enums;
  final Set<String> classes;

  _TypeResolver(this.enums, this.classes);

  _FieldType resolve(TypeAnnotation? annotation) {
    final raw = annotation?.toSource() ?? 'Object?';
    return _resolveString(raw);
  }

  _FieldType _resolveString(String raw) {
    final nullable = raw.endsWith('?');
    final base = nullable ? raw.substring(0, raw.length - 1).trim() : raw.trim();
    if (base.startsWith('List<') && base.endsWith('>')) {
      return _ListType(
          _resolveString(base.substring(5, base.length - 1).trim()), nullable);
    }
    switch (base) {
      case 'String':
      case 'int':
      case 'double':
      case 'bool':
        return _Prim(base, nullable);
    }
    if (enums.containsKey(base)) return _EnumType(base, enums[base], nullable);
    // Unknown custom types follow the DTO convention (fromJson/toJson).
    return _DtoType(base, nullable);
  }
}
