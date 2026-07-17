library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';

/// Reports canonical-form problems on DTO-shaped classes in [source]:
///
/// - `keta_canonical_missing`: a DTO that lacks a `fromJson` factory or a
///   `toJson` method.
/// - `keta_canonical_drift`: a DTO whose `toJson` map keys do not match its
///   final field names.
///
/// A class is a DTO by signal — it has a `Schema` constant, a `fromJson`, or a
/// `toJson` — never by the shape of its fields, so plain service/value classes
/// are never flagged. Purely syntactic; no resolution needed.
List<Diagnostic> canonicalDiagnostics(
  String source, {
  String file = '<memory>',
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final schemaNames = _schemaNames(unit);
  final diagnostics = <Diagnostic>[];
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration) {
      _checkClass(declaration, schemaNames, file, diagnostics);
    }
  }
  return diagnostics;
}

Set<String> _schemaNames(CompilationUnit unit) {
  final names = <String>{};
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
      if (isSchema && name != null) names.add(name);
    }
  }
  return names;
}

String? _firstStringArg(ArgumentList args) {
  final first = args.arguments.isEmpty ? null : args.arguments.first;
  return first is SimpleStringLiteral ? first.value : null;
}

void _checkClass(
  ClassDeclaration node,
  Set<String> schemaNames,
  String file,
  List<Diagnostic> diagnostics,
) {
  final finalFields = <String>[];
  ConstructorDeclaration? fromJson;
  MethodDeclaration? toJson;

  for (final member in node.body.members) {
    if (member is FieldDeclaration && !member.isStatic) {
      if (member.fields.isFinal) {
        for (final v in member.fields.variables) {
          if (v.initializer == null) finalFields.add(v.name.lexeme);
        }
      }
    } else if (member is ConstructorDeclaration) {
      if (member.factoryKeyword != null && member.name?.lexeme == 'fromJson') {
        fromJson = member;
      }
    } else if (member is MethodDeclaration && member.name.lexeme == 'toJson') {
      toJson = member;
    }
  }

  final nameToken = node.namePart.typeName;
  final className = nameToken.lexeme;
  // A DTO by signal only; abstract/sealed carriers are never canonical DTOs.
  final isDto =
      schemaNames.contains(className) || fromJson != null || toJson != null;
  if (!isDto || node.abstractKeyword != null || node.sealedKeyword != null) {
    return;
  }

  if (fromJson == null || toJson == null) {
    diagnostics.add(
      Diagnostic(
        rule: 'keta_canonical_missing',
        message:
            'class $className has final fields but no '
            '${fromJson == null ? 'fromJson factory' : 'toJson method'}; '
            'run keta_lints:fix to materialize the canonical mapper',
        file: file,
        scope: className,
        offset: nameToken.offset,
        length: nameToken.length,
      ),
    );
    return;
  }

  final jsonKeys = _toJsonKeys(toJson);
  if (jsonKeys == null) return; // hand-modified shape; not verified.
  if (!_isCanonicalFromJson(fromJson, className)) {
    return; // hand-modified shape; not verified — mirrors the toJson gate
    // above, so `keta_lints:fix` (which shares this same recognizer, see
    // fix.dart) is never recommended for a fromJson it will refuse to touch.
  }
  final fields = finalFields.toSet();
  // Verify BOTH directions of the round-trip: toJson writes exactly the fields,
  // and fromJson reads exactly the fields. A half-done rename (fromJson still
  // reading the old key) round-trips broken but a toJson-only check misses it.
  final fromKeys = _fromJsonKeys(fromJson);
  final parts = [
    if (fields.difference(jsonKeys).isNotEmpty)
      'fields not in toJson: ${fields.difference(jsonKeys).join(', ')}',
    if (jsonKeys.difference(fields).isNotEmpty)
      'toJson keys not fields: ${jsonKeys.difference(fields).join(', ')}',
    if (fields.difference(fromKeys).isNotEmpty)
      'fields not read by fromJson: ${fields.difference(fromKeys).join(', ')}',
    if (fromKeys.difference(fields).isNotEmpty)
      'fromJson reads unknown keys: ${fromKeys.difference(fields).join(', ')}',
  ];
  if (parts.isNotEmpty) {
    diagnostics.add(
      Diagnostic(
        rule: 'keta_canonical_drift',
        message:
            'class $className has drifted (${parts.join('; ')}); '
            'run keta_lints:fix to reconcile the mapper',
        file: file,
        scope: className,
        offset: nameToken.offset,
        length: nameToken.length,
      ),
    );
  }
}

/// Whether [fromJson]'s body is a recognizable canonical shape: a single
/// expression that is a direct call to the class's own default constructor
/// (`ClassName(...)`) — the shape `keta_lints:fix` itself generates. Mirrors
/// [_toJsonKeys] returning null for a non-canonical toJson at the same
/// granularity — it recognizes the outer shape (an expression-bodied factory
/// that instantiates the class directly) without verifying each argument's
/// inner expression, exactly as `_toJsonKeys`/[_isCanonicalMap]-in-fix.dart
/// recognize a map literal without verifying each entry's value.
///
/// A block body with local variables, or a fallback lookup spread across
/// statements (`final id = json['id'] ?? json['legacy_id']; return
/// Dto(id: id);`), does not match and is treated as hand-modified — the
/// fromJson key set below is only trustworthy, and only worth reporting drift
/// on, once this recognizes the shape. That keeps this diagnostic in
/// lockstep with what the fix (see fix.dart, which shares this exact
/// recognizer) can and cannot touch.
bool _isCanonicalFromJson(ConstructorDeclaration fromJson, String className) {
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
Set<String> _fromJsonKeys(ConstructorDeclaration fromJson) {
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

/// The string keys of the map [toJson] returns, or null if the body is not a
/// recognizable map literal (a hand-modified shape).
Set<String>? _toJsonKeys(MethodDeclaration toJson) {
  final body = toJson.body;
  Expression? returned;
  if (body is ExpressionFunctionBody) {
    returned = body.expression;
  } else if (body is BlockFunctionBody) {
    for (final statement in body.block.statements) {
      if (statement is ReturnStatement) returned = statement.expression;
    }
  }
  if (returned is! SetOrMapLiteral) return null;

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
