library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';

/// Reports string-syntax route problems in [source]:
///
/// - `keta_param_unknown`: `c.param('x')` where `x` is not a capture in the
///   route template.
/// - `keta_capture_unused`: a path capture that the handler never reads via
///   `c.param`.
///
/// Single-file and syntactic: it matches `app.<verb>('<path>', (c) { ... })`
/// registrations against the `param('...')` calls in the handler body.
List<Diagnostic> routeDiagnostics(String source, {String file = '<memory>'}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final diagnostics = <Diagnostic>[];
  unit.accept(_RouteVisitor(file, diagnostics));
  return diagnostics;
}

const _verbs = {'get', 'post', 'put', 'delete', 'patch', 'head', 'options'};

class _RouteVisitor extends RecursiveAstVisitor<void> {
  final String file;
  final List<Diagnostic> diagnostics;

  _RouteVisitor(this.file, this.diagnostics);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final args = node.argumentList.arguments;
    if (_verbs.contains(node.methodName.name) &&
        node.target != null &&
        args.length >= 2 &&
        args[0] is SimpleStringLiteral &&
        args[1] is FunctionExpression) {
      _check((args[0] as SimpleStringLiteral).value, args[1] as FunctionExpression);
    }
    super.visitMethodInvocation(node);
  }

  void _check(String path, FunctionExpression handler) {
    final captures = _captures(path);
    final used = <String>{};
    handler.body.accept(_ParamCollector(used));

    for (final name in used.difference(captures)) {
      diagnostics.add(Diagnostic(
        rule: 'keta_param_unknown',
        message: 'c.param(\'$name\') is not a capture in "$path"; '
            'add :$name to the route or fix the name',
        file: file,
        scope: '$path#$name',
      ));
    }
    for (final capture in captures.difference(used)) {
      diagnostics.add(Diagnostic(
        rule: 'keta_capture_unused',
        message: 'capture ":$capture" in "$path" is never read via c.param; '
            'read it or remove it from the route',
        file: file,
        scope: '$path#$capture',
      ));
    }
  }
}

class _ParamCollector extends RecursiveAstVisitor<void> {
  final Set<String> names;

  _ParamCollector(this.names);

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'param' &&
        node.argumentList.arguments.length == 1 &&
        node.argumentList.arguments.first is SimpleStringLiteral) {
      names.add((node.argumentList.arguments.first as SimpleStringLiteral).value);
    }
    super.visitMethodInvocation(node);
  }
}

Set<String> _captures(String path) => {
      for (final segment in path.split('/'))
        if (segment.startsWith(':') && segment.length > 1) segment.substring(1),
    };
