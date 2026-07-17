library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';

/// Reports query-parameter declaration/usage drift in [source]:
///
/// - `keta_query_undeclared`: `c.query('x')` (or `tryQuery`/`queryAll`) whose
///   name is not declared in the route's `RouteDoc(query: [...])`.
/// - `keta_query_drift`: a query param declared `required: true` but read with
///   `tryQuery` (the optional accessor).
///
/// Single-file and syntactic: it matches a route verb call's handler against the
/// `doc: RouteDoc(query: [...])` on the same call. When `doc` is present but not
/// an inspectable inline `RouteDoc` (e.g. a const reference), the declaration
/// cannot be seen and the checks are skipped rather than risk a false positive.
List<Diagnostic> queryDiagnostics(String source, {String file = '<memory>'}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final diagnostics = <Diagnostic>[];
  unit.accept(_QueryVisitor(file, diagnostics));
  return diagnostics;
}

const _verbs = {'get', 'post', 'put', 'delete', 'patch', 'head', 'options'};
const _accessors = {'query', 'tryQuery', 'queryAll'};

class _QueryVisitor extends RecursiveAstVisitor<void> {
  _QueryVisitor(this.file, this.diagnostics);
  final String file;
  final List<Diagnostic> diagnostics;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_verbs.contains(node.methodName.name) && node.target != null) {
      FunctionExpression? handler;
      for (final arg in node.argumentList.arguments) {
        if (arg is FunctionExpression) {
          handler = arg;
          break;
        }
      }
      if (handler != null) {
        _check(handler, _namedArg(node.argumentList, 'doc'));
      }
    }
    super.visitMethodInvocation(node);
  }

  void _check(FunctionExpression handler, Expression? doc) {
    final accesses = <(String, String, SimpleStringLiteral)>[];
    handler.body.accept(_QueryAccessCollector(accesses));
    if (accesses.isEmpty) return;

    final declared = _declaredQuery(doc);
    if (declared == null) return; // not an inspectable declaration

    for (final (name, accessor, literal) in accesses) {
      if (!declared.containsKey(name)) {
        diagnostics.add(
          Diagnostic(
            rule: 'keta_query_undeclared',
            message:
                "c.$accessor('$name') is not declared in RouteDoc.query; "
                "add QueryParam('$name', ...) or fix the name",
            file: file,
            scope: name,
            offset: literal.offset,
            length: literal.length,
          ),
        );
      } else if (declared[name] == true && accessor == 'tryQuery') {
        diagnostics.add(
          Diagnostic(
            rule: 'keta_query_drift',
            message:
                'query "$name" is declared required but read with tryQuery; '
                'use c.query for a required parameter (or drop required:)',
            file: file,
            scope: name,
            offset: literal.offset,
            length: literal.length,
          ),
        );
      }
    }
  }
}

/// The declared query params (name → required) from an inline `RouteDoc(query:
/// [...])`. Returns `{}` when [doc] is null (no declaration) and null when [doc]
/// is present but not an inspectable inline `RouteDoc`.
///
/// A constructor call without `const`/`new` parses (unresolved) as a
/// [MethodInvocation], so both forms are accepted.
Map<String, bool>? _declaredQuery(Expression? doc) {
  if (doc == null) return const {};
  final route = _ctor(doc);
  if (route == null || route.$1 != 'RouteDoc') return null;
  final queryArg = _namedArg(route.$2, 'query');
  if (queryArg == null) return const {};
  if (queryArg is! ListLiteral) return null;
  final result = <String, bool>{};
  for (final element in queryArg.elements) {
    if (element is! Expression) return null;
    final qp = _ctor(element);
    if (qp == null || qp.$1 != 'QueryParam') return null;
    String? name;
    for (final arg in qp.$2.arguments) {
      if (arg is SimpleStringLiteral) {
        name = arg.value;
        break;
      }
    }
    if (name == null) return null;
    final required = _namedArg(qp.$2, 'required');
    result[name] = required is BooleanLiteral && required.value;
  }
  return result;
}

/// The (name, arguments) of a constructor call, whether it parsed as an
/// [InstanceCreationExpression] (`const`/`new`) or a [MethodInvocation] (bare).
(String, ArgumentList)? _ctor(Expression e) => switch (e) {
  InstanceCreationExpression(:final constructorName, :final argumentList) => (
    constructorName.type.name.lexeme,
    argumentList,
  ),
  MethodInvocation(:final methodName, :final argumentList) => (
    methodName.name,
    argumentList,
  ),
  _ => null,
};

Expression? _namedArg(ArgumentList args, String name) {
  for (final arg in args.arguments) {
    if (arg is NamedArgument && arg.name.lexeme == name) {
      return arg.argumentExpression;
    }
  }
  return null;
}

class _QueryAccessCollector extends RecursiveAstVisitor<void> {
  _QueryAccessCollector(this.accesses);
  final List<(String, String, SimpleStringLiteral)> accesses;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final args = node.argumentList.arguments;
    if (_accessors.contains(node.methodName.name) &&
        args.length == 1 &&
        args.first is SimpleStringLiteral) {
      final literal = args.first as SimpleStringLiteral;
      accesses.add((literal.value, node.methodName.name, literal));
    }
    super.visitMethodInvocation(node);
  }
}
