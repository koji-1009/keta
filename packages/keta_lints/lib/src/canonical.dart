library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

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
List<Diagnostic> canonicalDiagnostics(String source, {String file = '<memory>'}) {
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
        InstanceCreationExpression(:final constructorName, :final argumentList) =>
          (_firstStringArg(argumentList), constructorName.type.name.lexeme == 'Schema'),
        MethodInvocation(:final methodName, :final argumentList) =>
          (_firstStringArg(argumentList), methodName.name == 'Schema'),
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

void _checkClass(ClassDeclaration node, Set<String> schemaNames, String file,
    List<Diagnostic> diagnostics) {
  final finalFields = <String>[];
  var hasFromJson = false;
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
        hasFromJson = true;
      }
    } else if (member is MethodDeclaration && member.name.lexeme == 'toJson') {
      toJson = member;
    }
  }

  final className = node.namePart.typeName.lexeme;
  // A DTO by signal only; abstract/sealed carriers are never canonical DTOs.
  final isDto = schemaNames.contains(className) || hasFromJson || toJson != null;
  if (!isDto || node.abstractKeyword != null || node.sealedKeyword != null) {
    return;
  }

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
