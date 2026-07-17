/// The single source of truth for *recognizing* a canonical-form DTO, shared by
/// the diagnostic layer (canonical.dart) and the materializing fixer (fix.dart).
///
/// Before this module the two duplicated their recognizers (the toJson/fromJson
/// key extractors, the field-type resolver) and — worse — their *decisions*:
/// canonical.dart never looked at the Schema constant or at whether the fixer
/// could actually act, so `check` and `fix` disagreed (a stale Schema passed
/// check while fix would rewrite it; a positional-ctor DTO was told to run a fix
/// that silently refused it). Having both call [CanonicalUnit]/[CanonicalClass]
/// makes them decide identically by construction: whatever the fixer would
/// touch is exactly what the check reports, and whatever the fixer refuses the
/// check refuses to recommend.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Unit-scoped context: the `Schema` constants, enums, and DTO names visible in
/// one compilation unit, plus the type resolver derived from them. Built once
/// per unit and threaded into every [CanonicalClass].
class CanonicalUnit {
  CanonicalUnit._(this.schemas, this.enums, this.dtoNames, this.resolver);

  factory CanonicalUnit.of(CompilationUnit unit) {
    final schemas = schemaInitializers(unit);
    final enums = <String, EnumInfo>{};
    // A class is a DTO by signal: a Schema constant, a fromJson factory, or a
    // toJson method — never by the shape of its fields (which is a guess).
    final dtoNames = <String>{...schemas.keys};
    for (final declaration in unit.declarations) {
      if (declaration is EnumDeclaration) {
        enums[declaration.namePart.typeName.lexeme] = _readEnumInfo(
          declaration,
        );
      } else if (declaration is ClassDeclaration && hasMapper(declaration)) {
        dtoNames.add(declaration.namePart.typeName.lexeme);
      }
    }
    return CanonicalUnit._(
      schemas,
      enums,
      dtoNames,
      TypeResolver(enums, dtoNames),
    );
  }

  /// `Schema('Name', …)` initializer expressions, keyed by the DTO name.
  final Map<String, Expression> schemas;

  /// Enum declarations in the unit, name → its constant/wire model.
  final Map<String, EnumInfo> enums;

  /// Every DTO name in the unit — Schema-declared or mapper-carrying — so a
  /// field typed as one of them resolves to a `$ref`.
  final Set<String> dtoNames;

  final TypeResolver resolver;
}

/// One class analyzed against the canonical form: its DTO-signal field set, the
/// mapper members, and — crucially — a single [refusalReason] that mirrors, in
/// order, every bail condition in the fixer. Check and fix consult the same
/// verdict, so they never diverge.
class CanonicalClass {
  CanonicalClass._({
    required this.node,
    required this.className,
    required this.fields,
    required this.allFinalFieldNames,
    required this.declaredTypes,
    required this.unresolvableField,
    required this.genCtor,
    required this.fromJson,
    required this.toJson,
  });

  final ClassDeclaration node;
  final String className;

  /// The final, non-static, initializer-free fields whose type is inside the
  /// canonical subset — the fields the mappers and Schema must cover.
  final List<CanonicalField> fields;

  /// The names of ALL final, non-static, initializer-free fields — including
  /// any whose type is outside the canonical subset. This is the desired key
  /// set the mapper and Schema must cover, independent of whether the fixer can
  /// materialize the field's type. Drift is reported against this set (a broken
  /// round-trip is a bug the user must know about even when the auto-fixer must
  /// decline); the resolvable [fields] subset is what the fixer generates from.
  final Set<String> allFinalFieldNames;

  /// True when some final, initializer-free field has a type *outside* the
  /// canonical subset (a cross-file enum, `DateTime`, a nested collection).
  /// The fixer refuses such a class rather than guess, so the check must too.
  final bool unresolvableField;

  /// Each final, non-static, initializer-free field's *declared* type, verbatim
  /// from source (e.g. `int`, `String?`, `List<Role>`), keyed by field name. It
  /// is the syntactic ground truth the fromJson `as T` cast is checked against
  /// for type drift; a field with no written type annotation is simply absent.
  final Map<String, String> declaredTypes;

  final ConstructorDeclaration? genCtor;
  final ConstructorDeclaration? fromJson;
  final MethodDeclaration? toJson;

  /// The recognized DTO's field names — the desired key set for both mappers
  /// and the Schema's `properties`.
  Set<String> get fieldNames => {for (final f in fields) f.name};

  Token get nameToken => node.namePart.typeName;

  /// Recognizes [node] as a canonical DTO, or returns null when it is not one
  /// the tooling touches at all: no DTO signal, `abstract`/`sealed` (a factory
  /// can't instantiate it), or an explicit `extends` clause. The last is a
  /// safe refusal — a subclass's full field set (and thus its toJson keys) is
  /// not derivable without resolving the superclass, so both diagnosing and
  /// regenerating would drop inherited keys. Returning null here makes check
  /// and fix ignore the class identically.
  static CanonicalClass? of(ClassDeclaration node, CanonicalUnit unit) {
    final className = node.namePart.typeName.lexeme;
    if (!unit.dtoNames.contains(className)) return null;
    if (node.abstractKeyword != null || node.sealedKeyword != null) return null;
    if (node.extendsClause != null) return null;

    final fields = <CanonicalField>[];
    final allFinalFieldNames = <String>{};
    final declaredTypes = <String, String>{};
    var unresolvable = false;
    ConstructorDeclaration? genCtor;
    ConstructorDeclaration? fromJson;
    MethodDeclaration? toJson;

    for (final member in node.body.members) {
      if (member is FieldDeclaration &&
          !member.isStatic &&
          member.fields.isFinal) {
        final declaredType = member.fields.type?.toSource();
        for (final v in member.fields.variables) {
          // Fields with initializers / `late` defaults aren't ctor parameters.
          if (v.initializer != null) continue;
          allFinalFieldNames.add(v.name.lexeme);
          if (declaredType != null) declaredTypes[v.name.lexeme] = declaredType;
          final type = unit.resolver.resolve(member.fields.type);
          if (type == null) {
            unresolvable = true;
          } else {
            fields.add(CanonicalField(v.name.lexeme, type));
          }
        }
      } else if (member is ConstructorDeclaration) {
        if (member.factoryKeyword == null) {
          genCtor = member;
        } else if (member.name?.lexeme == 'fromJson') {
          fromJson = member;
        }
      } else if (member is MethodDeclaration &&
          member.name.lexeme == 'toJson') {
        toJson = member;
      }
    }

    return CanonicalClass._(
      node: node,
      className: className,
      fields: fields,
      allFinalFieldNames: allFinalFieldNames,
      declaredTypes: declaredTypes,
      unresolvableField: unresolvable,
      genCtor: genCtor,
      fromJson: fromJson,
      toJson: toJson,
    );
  }

  /// Why the fixer would decline to materialize/reconcile this DTO, or null if
  /// it can act. The order mirrors the bail sequence in fix.dart `_fixClass`,
  /// so a diagnostic never recommends a no-op fix and never withholds one the
  /// fixer would perform. The phrase is embedded verbatim in the "materialize
  /// by hand" message so the user is told *which* property put the class out of
  /// reach.
  String? get refusalReason {
    if (unresolvableField) return 'a field type outside the canonical subset';
    if (fields.isEmpty) return 'no mappable final fields';
    if (genCtor == null) return 'no generative constructor';
    // The generated fromJson calls the ctor with NAMED args, so every field
    // must be a named parameter; a positional ctor would be miscompiled.
    final named = {
      for (final p in genCtor!.parameters.parameters)
        if (p.isNamed) p.name?.lexeme,
    };
    if (!fields.every((f) => named.contains(f.name))) {
      return 'a positional constructor';
    }
    // A present mapper the fixer can't recognize is hand-modified: it would be
    // flattened, so the fixer leaves the whole class alone.
    if (toJson != null && toJsonKeys(toJson!) == null) {
      return 'a hand-modified toJson';
    }
    if (fromJson != null && !isCanonicalFromJson(fromJson!, className)) {
      return 'a hand-modified fromJson';
    }
    return null;
  }

  /// Whether the fixer would act on this class (materialize or reconcile).
  bool get isFixable => refusalReason == null;

  /// Fields whose fromJson `as T` cast disagrees with the declared field type —
  /// the syntactic *type*-drift axis, orthogonal to the key-set drift the round-
  /// trip check covers (keys can line up perfectly while a type has silently
  /// changed underneath them). Delegates to [fromJsonTypeDrifts] so `check` and
  /// `fix` read the identical verdict; empty when there is no fromJson.
  List<TypeDrift> get typeDrifts {
    final fj = fromJson;
    if (fj == null) return const [];
    return fromJsonTypeDrifts(fj, declaredTypes);
  }
}

/// A field whose fromJson cast type ([cast]) no longer matches its [declared]
/// field type — one entry of the type-drift axis.
class TypeDrift {
  const TypeDrift(this.field, this.declared, this.cast);
  final String field;
  final String declared;
  final String cast;
}

/// The fromJson arguments whose `as T` cast has drifted from the field's
/// declared type in [declaredTypes]. ONLY a named argument of the bare shape
/// `field: json['key'] as T` is compared: there the cast token *is* the field
/// type, so a stale cast (a field retyped `String` while fromJson still reads
/// `as int`) or an optionality slip (`as int?` into a non-nullable `int`) is
/// genuine, wire-breaking drift. Enum/DTO/collection/`double` arguments cast to
/// a *transport* type (`String`, `Map`, `List`, `num`) inside a wrapping call,
/// carry no field-type token, and are deliberately skipped — comparing their
/// inner cast would be a false positive. Whitespace in both types is normalized
/// so pure formatting never reads as drift.
List<TypeDrift> fromJsonTypeDrifts(
  ConstructorDeclaration fromJson,
  Map<String, String> declaredTypes,
) {
  final arguments = _fromJsonArguments(fromJson);
  if (arguments == null) return const [];
  final drifts = <TypeDrift>[];
  for (final arg in arguments) {
    if (arg is! NamedArgument) continue;
    final field = arg.name.lexeme;
    final declared = declaredTypes[field];
    if (declared == null) continue;
    final expr = arg.argumentExpression;
    // Exactly the bare `json['key'] as T` shape — the whole argument is the
    // cast, so its type token is directly the field's type. Anything else
    // (a conditional, a wrapping `.byName(...)`/`.fromJson(...)`/`.toDouble()`)
    // is a transport cast and not comparable here.
    if (expr is! AsExpression || expr.expression is! IndexExpression) continue;
    final cast = expr.type.toSource();
    if (_normalizeType(cast) != _normalizeType(declared)) {
      drifts.add(TypeDrift(field, declared, cast));
    }
  }
  return drifts;
}

/// The argument list of a canonical fromJson body (`ClassName(...)`), or null
/// when the body is not that single-expression shape (a hand-modified block, a
/// fallback lookup) — matching [isCanonicalFromJson]'s outer-shape recognition.
NodeList<Argument>? _fromJsonArguments(ConstructorDeclaration fromJson) {
  final body = fromJson.body;
  if (body is! ExpressionFunctionBody) return null;
  return switch (body.expression) {
    InstanceCreationExpression(:final argumentList) => argumentList.arguments,
    MethodInvocation(:final argumentList) => argumentList.arguments,
    _ => null,
  };
}

/// Collapses all whitespace so `Map<String, int>` and `Map<String,int>` compare
/// equal — only the type token itself, never its formatting, signals drift.
String _normalizeType(String type) => type.replaceAll(RegExp(r'\s+'), '');

/// A resolved field: its Dart name and its place in the canonical type subset.
class CanonicalField {
  CanonicalField(this.name, this.type);
  final String name;
  final FieldType type;

  /// The field name escaped for embedding inside a generated single-quoted
  /// string literal — a name containing `$`, `'`, or `\` (all legal in a Dart
  /// identifier) must not become interpolation or an unterminated literal.
  String get keyLiteral => name
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');

  String fromJsonExpr() {
    final t = type;
    final key = keyLiteral;
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
    final key = keyLiteral;
    if (!type.nullable) return "        '$key': $value,";
    return "        if ($name != null) '$key': $value,";
  }
}

// --- enum recognition -----------------------------------------------------

/// An enum declaration seen in the unit. [constants] are the Dart constant
/// names as written; [wireValues] are the wire strings of a D-1 *enhanced* enum
/// (each constant's `('wire')` argument), or null for the plain form where the
/// constant name IS the wire string. Carrying both lets the shared recognizer
/// speak the wire vocabulary the mappers and the Schema `enum:` use, while the
/// Dart side keeps whatever identifiers it derived — the two diverge exactly
/// when a wire value is not a legal identifier, which is the whole reason the
/// enhanced form exists.
class EnumInfo {
  const EnumInfo(this.constants, this.wireValues);
  final List<String> constants;
  final List<String>? wireValues;

  bool get isEnhanced => wireValues != null;

  /// The strings on the wire and in the Schema `enum:` — the wire values when
  /// enhanced, else the constant names (which equal the wire strings in the
  /// plain form, so drift is always compared against the same vocabulary).
  List<String> get schemaValues => wireValues ?? constants;
}

/// Reads an [EnumDeclaration] into an [EnumInfo], recognizing the D-1 enhanced
/// form. The enhanced form is signalled by BOTH a `final String wire;` instance
/// field AND every constant carrying a single string-literal argument; requiring
/// both keeps an ordinary value-carrying enum (a different field, numeric args,
/// a partially-annotated constant list) from being misread as wire-mapped — such
/// an enum stays plain, its constant names taken as the wire strings, exactly as
/// before D-1. This is the sole place either check or fix learns an enum's wire
/// vocabulary, so both agree by construction.
EnumInfo _readEnumInfo(EnumDeclaration declaration) {
  final constants = declaration.body.constants;
  final names = [for (final c in constants) c.name.lexeme];
  final hasWireField = declaration.body.members.any(
    (m) =>
        m is FieldDeclaration &&
        !m.isStatic &&
        m.fields.isFinal &&
        m.fields.type?.toSource() == 'String' &&
        m.fields.variables.any((v) => v.name.lexeme == 'wire'),
  );
  if (!hasWireField) return EnumInfo(names, null);
  final wires = <String>[];
  for (final c in constants) {
    final args = c.arguments?.argumentList.arguments;
    final first = (args != null && args.length == 1) ? args.first : null;
    if (first is SimpleStringLiteral) wires.add(first.value);
  }
  // Only a *total* wire mapping — every constant supplied its string — is the
  // canonical enhanced shape; a partial one is treated as a hand-written enum
  // and left in the plain (name-is-wire) vocabulary rather than half-read.
  if (wires.length != names.length) return EnumInfo(names, null);
  return EnumInfo(names, wires);
}

// --- schema constant recognition ------------------------------------------

/// The `Schema('Name', …)` initializer expressions in [unit], keyed by name.
Map<String, Expression> schemaInitializers(CompilationUnit unit) {
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

/// The map literal argument of a `Schema('Name', {…})` initializer, or null.
SetOrMapLiteral? schemaMap(Expression init) {
  final args = switch (init) {
    InstanceCreationExpression(:final argumentList) => argumentList.arguments,
    MethodInvocation(:final argumentList) => argumentList.arguments,
    _ => null,
  };
  if (args == null || args.length < 2) return null;
  final map = args[1];
  return map is SetOrMapLiteral ? map : null;
}

/// The `properties: {…}` sub-literal of a schema map, or null.
SetOrMapLiteral? propertiesLiteral(SetOrMapLiteral map) {
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

/// The property names declared in a `Schema` initializer's `properties` map —
/// the key set the check compares against the DTO's fields, and the fixer
/// re-derives.
Set<String> schemaPropertyNames(Expression init) {
  final map = schemaMap(init);
  final props = map == null ? null : propertiesLiteral(map);
  if (props == null) return const {};
  return {
    for (final e in props.elements)
      if (e is MapLiteralEntry && e.key is SimpleStringLiteral)
        (e.key as SimpleStringLiteral).value,
  };
}

// --- mapper recognition ---------------------------------------------------

bool hasMapper(ClassDeclaration node) {
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

/// Whether [fromJson]'s body is a recognizable canonical shape: a single
/// expression that is a direct call to the class's own default constructor
/// (`ClassName(...)`) — the shape the fixer itself generates. It recognizes the
/// outer shape without verifying each argument's inner expression, exactly as
/// [toJsonKeys] recognizes a map literal without verifying each entry's value.
///
/// A block body with local variables, or a fallback lookup spread across
/// statements (`final id = json['id'] ?? json['legacy_id']; return Dto(id:
/// id);`), does not match and is treated as hand-modified — that is what makes
/// a hand-written back-compat alias fromJson survive the fix instead of being
/// silently collapsed to the naive one-liner.
bool isCanonicalFromJson(ConstructorDeclaration fromJson, String className) {
  final body = fromJson.body;
  if (body is! ExpressionFunctionBody) return false;
  return switch (body.expression) {
    InstanceCreationExpression(:final constructorName)
        when constructorName.type.name.lexeme == className &&
            constructorName.name == null =>
      true,
    MethodInvocation(:final methodName) when methodName.name == className =>
      true,
    _ => false,
  };
}

/// The string keys read via `…['key']` inside the fromJson factory (regardless
/// of the map parameter's name), i.e. the wire keys fromJson consumes.
Set<String> fromJsonKeys(ConstructorDeclaration fromJson) {
  final keys = <String>{};
  fromJson.visitChildren(_IndexKeyVisitor(keys));
  return keys;
}

class _IndexKeyVisitor extends RecursiveAstVisitor<void> {
  _IndexKeyVisitor(this.keys);
  final Set<String> keys;
  @override
  void visitIndexExpression(IndexExpression node) {
    final index = node.index;
    if (index is SimpleStringLiteral) keys.add(index.value);
    super.visitIndexExpression(node);
  }
}

/// The string keys of the map [toJson] returns, or null when the body is not a
/// *plainly enumerable* key set — not a map literal at all, or a map literal
/// carrying a spread (`...other`), a collection-`for`, or a non-literal key.
///
/// Returning null (rather than a partial set) for those is load-bearing: such a
/// literal is hand-authored, and reading it as an incomplete key set produced a
/// false drift *and* let the fixer flatten the member, dropping the spread. A
/// null here routes both check and fix to the same "leave it alone" posture as
/// the other hand-modified gates. Conditional entries (`if (x != null) 'k': v`)
/// are the one composite the fixer itself emits, so they are recognized.
Set<String>? toJsonKeys(MethodDeclaration toJson) {
  final returned = _returnedMap(toJson);
  if (returned == null) return null;
  final keys = <String>{};
  bool collect(Iterable<CollectionElement> elements) {
    for (final element in elements) {
      switch (element) {
        case MapLiteralEntry(:final key):
          if (key is! SimpleStringLiteral) return false; // computed key
          keys.add(key.value);
        case IfElement():
          if (!collect([element.thenElement])) return false;
          if (element.elseElement != null && !collect([element.elseElement!])) {
            return false;
          }
        default:
          return false; // spread, collection-for, or anything unrecognized
      }
    }
    return true;
  }

  return collect(returned.elements) ? keys : null;
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

bool setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

// --- field / type model ---------------------------------------------------

sealed class FieldType {
  const FieldType(this.nullable);
  final bool nullable;

  String fromJson(String access);
  String toJson(String name, {required bool nullable});
  Object? schemaJson();
  void collectDtoRefs(Set<String> into) {}
}

class _Prim extends FieldType {
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

class _EnumType extends FieldType {
  const _EnumType(this.name, this.values, this.enhanced, super.nullable);
  final String name;

  /// The wire strings — the Schema `enum:` list and what fromWire matches on.
  final List<String>? values;

  /// A D-1 enhanced (wire-mapped) enum, whose constant names are not the wire
  /// strings, so the mappers route through `fromWire`/`.wire` instead of the
  /// name-based `values.byName`/`.name`.
  final bool enhanced;

  @override
  String fromJson(String access) => enhanced
      ? '$name.fromWire($access as String)'
      : '$name.values.byName($access as String)';
  @override
  String toJson(String field, {required bool nullable}) {
    final accessor = enhanced ? 'wire' : 'name';
    return nullable ? '$field!.$accessor' : '$field.$accessor';
  }

  @override
  Object? schemaJson() => {
    'type': 'string',
    if (values != null) 'enum': values,
  };
}

class _DtoType extends FieldType {
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

class _ListType extends FieldType {
  const _ListType(this.item, super.nullable);
  final FieldType item;

  @override
  String fromJson(String access) => switch (item) {
    _Prim(dart: 'double') =>
      '($access as List).map((e) => (e as num).toDouble()).toList()',
    _Prim(:final dart) => '($access as List).cast<$dart>()',
    _EnumType(:final name, enhanced: true) =>
      '($access as List).map((e) => $name.fromWire(e as String)).toList()',
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
      _EnumType(enhanced: true) => '$f.map((e) => e.wire).toList()',
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

class _MapType extends FieldType {
  const _MapType(this.value, super.nullable);
  final FieldType value;

  @override
  String fromJson(String access) => switch (value) {
    _Prim(dart: 'double') =>
      '($access as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble()))',
    _Prim(:final dart) => '($access as Map).cast<String, $dart>()',
    _EnumType(:final name, enhanced: true) =>
      '($access as Map).map((k, v) => MapEntry(k as String, $name.fromWire(v as String)))',
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
      _EnumType(enhanced: true) => '$f.map((k, v) => MapEntry(k, v.wire))',
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

class TypeResolver {
  TypeResolver(this.enums, this.dtoNames);
  final Map<String, EnumInfo> enums;
  final Set<String> dtoNames;

  /// Resolves a field's type within the canonical subset, or null when it can't
  /// be resolved from this file (a cross-file enum, or a non-canonical type).
  FieldType? resolve(TypeAnnotation? annotation) =>
      _resolveString(annotation?.toSource() ?? 'Object?');

  FieldType? _resolveString(String raw) {
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
    final enumInfo = enums[base];
    if (enumInfo != null) {
      return _EnumType(
        base,
        enumInfo.schemaValues,
        enumInfo.isEnhanced,
        nullable,
      );
    }
    if (dtoNames.contains(base)) return _DtoType(base, nullable);
    return null; // unknown/cross-file/non-canonical
  }
}
