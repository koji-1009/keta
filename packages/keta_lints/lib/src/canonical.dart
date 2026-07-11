library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'diagnostic.dart';

/// Analyzes DTO-shaped classes in [source] and reports canonical-form problems:
///
/// - `keta_canonical_missing`: a class with final fields and a generative
///   constructor that lacks a `fromJson` factory or a `toJson` method.
/// - `keta_canonical_drift`: a class whose `toJson` map keys do not match its
///   final field names.
///
/// Purely syntactic — it parses [source], so it needs no resolution.
List<Diagnostic> canonicalDiagnostics(String source, {String file = '<memory>'}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final diagnostics = <Diagnostic>[];
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration) {
      _checkClass(declaration, file, diagnostics);
    }
  }
  return diagnostics;
}

void _checkClass(
    ClassDeclaration node, String file, List<Diagnostic> diagnostics) {
  final finalFields = <String>[];
  var hasGenerativeCtor = false;
  var hasFromJson = false;
  MethodDeclaration? toJson;

  for (final member in node.body.members) {
    if (member is FieldDeclaration && !member.isStatic) {
      if (member.fields.isFinal) {
        for (final v in member.fields.variables) {
          finalFields.add(v.name.lexeme);
        }
      }
    } else if (member is ConstructorDeclaration) {
      if (member.factoryKeyword == null) {
        hasGenerativeCtor = true;
      } else if (member.name?.lexeme == 'fromJson') {
        hasFromJson = true;
      }
    } else if (member is MethodDeclaration && member.name.lexeme == 'toJson') {
      toJson = member;
    }
  }

  // Not DTO-shaped: skip classes with no final fields or no constructor.
  if (finalFields.isEmpty || !hasGenerativeCtor) return;

  final className = node.namePart.typeName.lexeme;
  if (!hasFromJson || toJson == null) {
    diagnostics.add(Diagnostic(
      rule: 'keta_canonical_missing',
      message: 'class $className has final fields but no '
          '${!hasFromJson ? 'fromJson factory' : 'toJson method'}; '
          'run keta_lints:fix to materialize the canonical mapper',
      file: file,
      scope: className,
    ));
    return;
  }

  final jsonKeys = _toJsonKeys(toJson);
  if (jsonKeys == null) return; // hand-modified shape; not verified.
  final fields = finalFields.toSet();
  final missing = fields.difference(jsonKeys);
  final extra = jsonKeys.difference(fields);
  if (missing.isNotEmpty || extra.isNotEmpty) {
    final parts = [
      if (missing.isNotEmpty) 'fields not in toJson: ${missing.join(', ')}',
      if (extra.isNotEmpty) 'toJson keys not fields: ${extra.join(', ')}',
    ];
    diagnostics.add(Diagnostic(
      rule: 'keta_canonical_drift',
      message: 'class $className has drifted (${parts.join('; ')}); '
          'run keta_lints:fix to reconcile the mapper',
      file: file,
      scope: className,
    ));
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
