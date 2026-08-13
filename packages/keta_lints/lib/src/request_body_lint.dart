library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';
import 'http_methods.dart';

/// Reports request-body declaration/handler drift in [source]:
///
/// - `keta_request_body_unvalidated`: a route declares
///   `RouteDoc(requestBody: xSchema)` and reads the body, but never validates it
///   against `xSchema`.
/// - `keta_request_body_drift`: it validates against a *different* schema than
///   the one it declared.
///
/// `RouteDoc.requestBody` is projected into the OpenAPI document and read by
/// nothing at runtime — only `security` is, by `enforceSecurity`. So a declared
/// `requestBody` is a promise the document makes and the boundary keeps only if
/// the handler also calls `schema.require`/`requireMap` itself. This closes that
/// gap the same way `keta_query_undeclared`/`keta_query_drift` close it for
/// `RouteDoc(query: [...])`: at build time, with no hidden middleware and no
/// change to what the framework does at runtime.
///
/// Single-file and syntactic, and deliberately conservative — every ambiguity is
/// a skip rather than a finding:
///
/// * `doc:` present but not an inspectable inline `RouteDoc` (a const reference)
///   → skipped; the declaration cannot be read.
/// * `requestBody:` not a plain identifier (a composed expression) → skipped;
///   there is no name to compare a `require` target against.
/// * the handler never reads the body (no `c.body()`/`bodyBytes()`/
///   `bodyStream()`) → skipped. Validation may legitimately live in a helper
///   this file cannot see, and a handler that reads nothing is not the drift
///   this rule is about.
///
/// The consequence of that last skip: a handler that delegates the whole read to
/// a helper is never flagged. That is the intended trade — a false negative is a
/// missed reminder, a false positive is a broken CI gate on correct code.
List<Diagnostic> requestBodyDiagnostics(
  String source, {
  String file = '<memory>',
}) => requestBodyDiagnosticsUnit(
  parseString(content: source, throwIfDiagnostics: false).unit,
  file: file,
);

/// [requestBodyDiagnostics] over an already-parsed [unit].
List<Diagnostic> requestBodyDiagnosticsUnit(
  CompilationUnit unit, {
  String file = '<memory>',
}) {
  final diagnostics = <Diagnostic>[];
  unit.accept(_RequestBodyVisitor(file, diagnostics));
  return diagnostics;
}

/// The `Context` accessors that read the request body. Any of them means the
/// handler is handling a body here, so the declaration binds here too.
const _bodyReaders = {'body', 'bodyBytes', 'bodyStream'};

/// The `Schema` methods that gate a value at the boundary.
const _validators = {'require', 'requireMap'};

class _RequestBodyVisitor(final String file, final List<Diagnostic> diagnostics)
    extends RecursiveAstVisitor<void> {
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (httpMethods.contains(node.methodName.name) && node.target != null) {
      FunctionExpression? handler;
      String? path;
      for (final arg in node.argumentList.arguments) {
        if (arg is FunctionExpression) {
          handler ??= arg;
        } else if (arg is SimpleStringLiteral) {
          path ??= arg.value;
        }
      }
      if (handler != null) {
        _check(
          node.methodName.name,
          path ?? '',
          handler,
          _namedArg(node.argumentList, 'doc'),
        );
      }
    }
    super.visitMethodInvocation(node);
  }

  void _check(
    String method,
    String path,
    FunctionExpression handler,
    Expression? doc,
  ) {
    final declared = _declaredRequestBody(doc);
    if (declared == null) return; // nothing declared, or not inspectable

    final uses = _HandlerUses();
    handler.body.accept(uses);
    // No body read in this handler: validation may live in a helper this file
    // cannot see. Skip rather than guess.
    final reader = uses.bodyRead;
    if (reader == null) return;
    if (uses.validatedBy.contains(declared.name)) return;

    // A require on some *other* schema is a different, sharper fact than none at
    // all: the handler validated, against the wrong contract.
    final other = uses.validatedBy.where((s) => s != declared.name).firstOrNull;
    diagnostics.add(
      other != null
          ? Diagnostic(
              rule: 'keta_request_body_drift',
              message:
                  'RouteDoc declares requestBody: ${declared.name} but the '
                  'handler validates with $other; the document and the boundary '
                  'describe different bodies',
              file: file,
              // Route-qualified, as the query rules are: the same schema can be
              // declared on two routes in one file, and a byte offset would not
              // survive an edit elsewhere.
              scope: '$method $path#requestBody',
              offset: declared.offset,
              length: declared.length,
            )
          : Diagnostic(
              rule: 'keta_request_body_unvalidated',
              message:
                  'RouteDoc declares requestBody: ${declared.name} but the '
                  'handler reads the body without validating it; add '
                  '${declared.name}.requireMap(await c.body()) — the '
                  'declaration is emitted into OpenAPI and enforced by nothing '
                  'at runtime',
              file: file,
              scope: '$method $path#requestBody',
              offset: reader.offset,
              length: reader.length,
            ),
    );
  }
}

/// The declared `requestBody` identifier from an inline `RouteDoc(...)`, or null
/// when there is nothing to check: no `doc:`, no `requestBody:`, a `doc:` that is
/// not an inspectable inline `RouteDoc`, or a `requestBody:` that is not a plain
/// identifier to compare against.
({String name, int offset, int length})? _declaredRequestBody(Expression? doc) {
  if (doc == null) return null;
  final route = _ctor(doc);
  if (route == null || route.$1 != 'RouteDoc') return null;
  final body = _namedArg(route.$2, 'requestBody');
  if (body is! SimpleIdentifier) return null;
  return (name: body.name, offset: body.offset, length: body.length);
}

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

/// What a handler body does with the request body: where it first reads one, and
/// the schema identifiers it gates a value with.
class _HandlerUses extends RecursiveAstVisitor<void> {
  /// The first `c.body()`-family call, or null when the handler reads no body.
  /// Carries the offset so the finding points at the read, not at the route.
  ({int offset, int length})? bodyRead;

  /// Every identifier `X` in an `X.require(...)` / `X.requireMap(...)` call.
  final Set<String> validatedBy = {};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (_bodyReaders.contains(name) && node.target != null) {
      bodyRead ??= (offset: node.offset, length: node.length);
    }
    if (_validators.contains(name)) {
      final target = node.target;
      if (target is SimpleIdentifier) validatedBy.add(target.name);
    }
    super.visitMethodInvocation(node);
  }
}
