library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';

/// Flags a middleware chain that registers `use(tx())` OUTSIDE (before)
/// `use(recover())`.
///
/// Middleware runs outermost-first in registration order, so `..use(tx())..use(
/// recover())` puts recover() *inside* tx(): recover converts a thrown error to
/// a Response before it reaches tx(), and the transaction commits the writes of
/// a request that actually failed. The correct order registers recover() first:
/// `..use(recover())..use(tx())`. Detection is scoped to a single cascade (the
/// idiomatic `app..use(...)..use(...)` form).
///
/// The [String] entrypoint parses [source] (the CLI path); the plugin holds a
/// parsed unit and calls [txOrderDiagnosticsUnit], so it never re-parses.
List<Diagnostic> txOrderDiagnostics(String source, {String file = '<memory>'}) =>
    txOrderDiagnosticsUnit(
      parseString(content: source, throwIfDiagnostics: false).unit,
      file: file,
    );

/// [txOrderDiagnostics] over an already-parsed [unit].
List<Diagnostic> txOrderDiagnosticsUnit(
  CompilationUnit unit, {
  String file = '<memory>',
}) {
  final diagnostics = <Diagnostic>[];
  unit.accept(
    _CascadeVisitor((offset, length) {
      diagnostics.add(
        Diagnostic(
          rule: 'keta_tx_outside_recover',
          message:
              'use(tx()) is registered outside use(recover()): the inner '
              'recover() converts a thrown error to a Response before it reaches '
              'tx(), so the transaction commits a failed request. Register '
              'recover() first — ..use(recover())..use(tx())',
          file: file,
          scope: 'tx@$offset',
          offset: offset,
          length: length,
        ),
      );
    }),
  );
  return diagnostics;
}

class _CascadeVisitor extends RecursiveAstVisitor<void> {
  _CascadeVisitor(this.report);
  final void Function(int txOffset, int txLength) report;

  @override
  void visitCascadeExpression(CascadeExpression node) {
    int? recoverOffset;
    int? txOffset;
    int? txLength;
    for (final section in node.cascadeSections) {
      final mw = _useMiddleware(section);
      if (mw == null) continue;
      if (mw.$1 == 'recover') recoverOffset ??= mw.$2;
      if (mw.$1 == 'tx' && txOffset == null) {
        txOffset = mw.$2;
        txLength = mw.$3;
      }
    }
    // Flag only when both are present and tx() is registered first (outer).
    // tx() without recover() is fine — the core's last-resort fallback runs
    // outside all app middleware, so a rollback still precedes it.
    if (txOffset != null && recoverOffset != null && txOffset < recoverOffset) {
      report(txOffset, txLength!);
    }
    super.visitCascadeExpression(node);
  }
}

/// If [section] is a `..use(mw())` cascade section, returns `(mwName, offset,
/// length)` of the inner middleware call.
(String, int, int)? _useMiddleware(Expression section) {
  if (section is! MethodInvocation || section.methodName.name != 'use') {
    return null;
  }
  final args = section.argumentList.arguments;
  if (args.length != 1) return null;
  final arg = args.first;
  return arg is MethodInvocation
      ? (arg.methodName.name, arg.offset, arg.length)
      : null;
}
