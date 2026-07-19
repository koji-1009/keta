library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';
import 'http_methods.dart';

/// Reports string-syntax route problems in [source]:
///
/// - `keta_param_unknown`: `c.param('x')` where `x` is not a capture in the
///   route template.
/// - `keta_capture_unused`: a path capture that the handler never reads via
///   `c.param`.
///
/// Single-file and syntactic: it matches `app.<verb>('<path>', (c) { ... })`
/// registrations against the `param('...')` calls in the handler body.
///
/// The [String] entrypoint parses [source] itself (the CLI path); the analyzer
/// plugin already holds a parsed unit and calls [routeDiagnosticsUnit] directly,
/// so no rule re-parses a file the analyzer has already parsed.
List<Diagnostic> routeDiagnostics(String source, {String file = '<memory>'}) =>
    routeDiagnosticsUnit(
      parseString(content: source, throwIfDiagnostics: false).unit,
      file: file,
    );

/// [routeDiagnostics] over an already-parsed [unit].
List<Diagnostic> routeDiagnosticsUnit(
  CompilationUnit unit, {
  String file = '<memory>',
}) {
  final diagnostics = <Diagnostic>[];
  unit.accept(_RouteVisitor(file, diagnostics));
  return diagnostics;
}

class _RouteVisitor extends RecursiveAstVisitor<void> {
  _RouteVisitor(this.file, this.diagnostics);
  final String file;
  final List<Diagnostic> diagnostics;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final args = node.argumentList.arguments;
    if (httpMethods.contains(node.methodName.name) &&
        node.target != null &&
        args.length >= 2 &&
        args[0] is SimpleStringLiteral &&
        args[1] is FunctionExpression) {
      _check(
        node.methodName.name,
        args[0] as SimpleStringLiteral,
        args[1] as FunctionExpression,
      );
    }
    super.visitMethodInvocation(node);
  }

  void _check(
    String method,
    SimpleStringLiteral pathLiteral,
    FunctionExpression handler,
  ) {
    final path = pathLiteral.value;
    final captures = _captures(path);
    final used = <String, SimpleStringLiteral>{};
    handler.body.accept(_ParamCollector(used));

    for (final name in used.keys.toSet().difference(captures)) {
      final at = used[name]!;
      diagnostics.add(
        Diagnostic(
          rule: 'keta_param_unknown',
          message:
              'c.param(\'$name\') is not a capture in "$path"; '
              'add :$name to the route or fix the name',
          file: file,
          // Two verbs on one path can reference the same unknown capture, so the
          // scope keys on the METHOD too — `POST /p` and `GET /p` are distinct
          // findings with distinct ids. Method+path names the route stably
          // (unlike a byte offset, which drifts on any edit above the call).
          scope: '$method $path#$name',
          offset: at.offset,
          length: at.length,
        ),
      );
    }
    for (final capture in captures.difference(used.keys.toSet())) {
      diagnostics.add(
        Diagnostic(
          rule: 'keta_capture_unused',
          message:
              'capture ":$capture" in "$path" is never read via c.param; '
              'read it or remove it from the route',
          file: file,
          // Method-qualified for the same reason as keta_param_unknown above:
          // the same path registered under two verbs is two distinct findings.
          scope: '$method $path#$capture',
          offset: pathLiteral.offset,
          length: pathLiteral.length,
        ),
      );
    }
  }
}

class _ParamCollector extends RecursiveAstVisitor<void> {
  _ParamCollector(this.names);

  /// Each read name mapped to the string literal of its first `c.param('...')`
  /// occurrence, so an unknown-param diagnostic points at the offending call.
  final Map<String, SimpleStringLiteral> names;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'param' &&
        node.argumentList.arguments.length == 1 &&
        node.argumentList.arguments.first is SimpleStringLiteral) {
      final literal = node.argumentList.arguments.first as SimpleStringLiteral;
      names.putIfAbsent(literal.value, () => literal);
    }
    super.visitMethodInvocation(node);
  }
}

Set<String> _captures(String path) => {
  for (final segment in path.split('/'))
    if (segment.startsWith(':') && segment.length > 1) segment.substring(1),
};
