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

class _RouteVisitor(final String file, final List<Diagnostic> diagnostics)
    extends RecursiveAstVisitor<void> {
  /// Prefixes of names bound to a group in this file:
  /// `final api = app.group('/api')` records `api -> '/api'`.
  ///
  /// A name that is not here is assumed to be the app itself (prefix `''`),
  /// which is what the rule always did. That assumption is right for
  /// `app.get(...)` and for the `void register(App<Env> app)` shape the
  /// examples use, and it is what keeps this rule syntactic and single-file.
  /// It is wrong only for a group arriving from outside the file — a
  /// `RouteGroup` parameter — which is why that shape is named in the rule's
  /// documented limits rather than silently mis-reported.
  final _groupPrefixes = <String, String>{};

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final prefix = _groupPrefixOf(node.initializer);
    if (prefix != null) _groupPrefixes[node.name.lexeme] = prefix;
    super.visitVariableDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final args = node.argumentList.arguments;
    if (httpMethods.contains(node.methodName.name) &&
        args.length >= 2 &&
        args[0] is SimpleStringLiteral &&
        args[1] is FunctionExpression) {
      // The registration's full template is the group prefix plus the literal.
      // The literal alone is not it: a capture in the prefix is readable via
      // `c.param` and would be reported as unknown, and two routes under
      // different prefixes sharing a relative path would collide on one id.
      _check(
        node.methodName.name,
        _prefixOfTarget(node),
        args[0] as SimpleStringLiteral,
        args[1] as FunctionExpression,
      );
    }
    super.visitMethodInvocation(node);
  }

  /// The group prefix of whatever [node] registers on; `''` when it is the app
  /// (or anything this file cannot see as a group).
  String _prefixOfTarget(MethodInvocation node) {
    final target = node.target;
    if (target != null) return _groupPrefixOf(target) ?? '';
    // A cascade section carries no target of its own; the router is the
    // cascade's. `app.group('/admin')..get('/x', h)` lands here.
    for (AstNode? n = node.parent; n != null; n = n.parent) {
      if (n is CascadeExpression) return _groupPrefixOf(n.target) ?? '';
      if (n is FunctionBody) break; // left the expression; no cascade above
    }
    return '';
  }

  /// The prefix an expression contributes when it denotes a GROUP, or null when
  /// it does not denote one this file can see.
  String? _groupPrefixOf(Expression? expr) {
    switch (expr) {
      case SimpleIdentifier():
        return _groupPrefixes[expr.name];
      case MethodInvocation(methodName: final m) when m.name == 'group':
        final args = expr.argumentList.arguments;
        if (args.length != 1 || args.first is! SimpleStringLiteral) return null;
        // Groups nest: `app.group('/a').group('/b')` is '/a/b'. An unresolvable
        // receiver contributes nothing rather than poisoning the whole prefix.
        final outer = expr.target == null
            ? ''
            : _groupPrefixOf(expr.target) ?? '';
        return _join(outer, (args.first as SimpleStringLiteral).value);
      // `app.group('/a')..use(m)` used directly as a router expression.
      case CascadeExpression():
        return _groupPrefixOf(expr.target);
      case ParenthesizedExpression():
        return _groupPrefixOf(expr.expression);
      default:
        return null;
    }
  }

  static String _join(String prefix, String rest) {
    if (prefix.isEmpty) return rest;
    final a = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    final b = rest.startsWith('/') ? rest : '/$rest';
    return '$a$b';
  }

  void _check(
    String method,
    String prefix,
    SimpleStringLiteral pathLiteral,
    FunctionExpression handler,
  ) {
    final path = _join(prefix, pathLiteral.value);
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

class _ParamCollector(
  /// Each read name mapped to the string literal of its first `c.param('...')`
  /// occurrence, so an unknown-param diagnostic points at the offending call.
  final Map<String, SimpleStringLiteral> names,
) extends RecursiveAstVisitor<void> {
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
