library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:keta/keta.dart';

import 'diagnostic.dart';

/// Flags a `use(...)` run whose middleware positions descend instead of
/// ascending outward-to-inward.
///
/// The ranks come from `package:keta`'s own [KetaOrder] constants — the very
/// values `App.compile` compares — so this rule and the runtime cannot disagree
/// about which pair is inverted. What lives here is only the *name* table: an
/// unresolved parse cannot follow `gzip` to its declaration, and the names of
/// keta_db's and keta_oidc's middleware cannot be imported from ring 1 at all.
///
/// This is the fast, partial half. `App.compile` reads the chain a request
/// actually gets — across `use()` calls that no single expression contains, and
/// per route, since group middleware is snapshotted at registration — and is
/// what guarantees the ordering. This rule sees only a run of `use()` calls
/// written together, so it misses what it cannot see; it never invents a
/// violation, which is the property worth having in an editor.
///
/// The `tx`/`recover` pair is left to `keta_tx_outside_recover`, which reports
/// it with its own message and its own stable id.
List<Diagnostic> middlewareOrderDiagnostics(
  String source, {
  String file = '<memory>',
}) => middlewareOrderDiagnosticsUnit(
  parseString(content: source, throwIfDiagnostics: false).unit,
  file: file,
);

/// [middlewareOrderDiagnostics] over an already-parsed [unit].
List<Diagnostic> middlewareOrderDiagnosticsUnit(
  CompilationUnit unit, {
  String file = '<memory>',
}) {
  final diagnostics = <Diagnostic>[];
  unit.accept(
    _OrderVisitor((inner, outer) {
      diagnostics.add(
        Diagnostic(
          rule: 'keta_middleware_order',
          message:
              'use(${inner.name}()) is registered inside use(${outer.name}()), '
              'but ${inner.name}() carries the outer position '
              '"${inner.order.name}" (rank ${inner.order.rank}) and '
              '${outer.name}() carries "${outer.order.name}" (rank '
              '${outer.order.rank}). Registration order is outermost-first, so '
              'register ${inner.name}() first — or pass `order:` to place one '
              'of them deliberately.',
          file: file,
          scope: 'middlewareOrder@${inner.offset}',
          offset: inner.offset,
          length: inner.length,
        ),
      );
    }),
  );
  return diagnostics;
}

/// One `use(mw())` in a run, with the position [mw] was recognized as carrying.
class _Use {
  _Use(this.name, this.order, this.offset, this.length);
  final String name;
  final MiddlewareOrder order;
  final int offset;
  final int length;
}

/// The position each of keta's middleware factories tags its result with.
///
/// The ranks are read from [KetaOrder], never restated: editing a rank in
/// `package:keta` moves this rule with it. Only the mapping from a *written
/// name* to a position lives here, because that is the part an unresolved parse
/// cannot recover. A name this table does not know is unconstrained, exactly as
/// an untagged middleware is at runtime.
const Map<String, MiddlewareOrder> _positions = {
  'accessLog': KetaOrder.observe,
  'cors': KetaOrder.crossOrigin,
  'recover': KetaOrder.recover,
  'rateLimit': KetaOrder.shed,
  'concurrencyLimit': KetaOrder.shed,
  'timeout': KetaOrder.deadline,
  'gzip': KetaOrder.negotiate,
  'etag': KetaOrder.validate,
  'enforceSecurity': KetaOrder.authenticate,
  'oidc': KetaOrder.authenticate,
  'requireScopes': KetaOrder.authorize,
  'tx': KetaOrder.resource,
};

/// The pair `keta_tx_outside_recover` owns, so one mistake is not reported
/// twice under two ids.
bool _ownedByTxRule(String inner, String outer) =>
    inner == 'recover' && outer == 'tx';

class _OrderVisitor extends RecursiveAstVisitor<void> {
  _OrderVisitor(this.report);
  final void Function(_Use inner, _Use outer) report;

  /// `app..use(a())..use(b())` — the idiomatic form.
  @override
  void visitCascadeExpression(CascadeExpression node) {
    _check([for (final section in node.cascadeSections) ..._useOf(section)]);
    super.visitCascadeExpression(node);
  }

  /// `app.use(a()); app.use(b());` — the same registration written as
  /// statements. Only a consecutive run on the same receiver is one chain; any
  /// other statement between them breaks it, since what it does to the app is
  /// not readable from here.
  @override
  void visitBlock(Block node) {
    var run = <_Use>[];
    String? receiver;
    for (final statement in node.statements) {
      final invocation = statement is ExpressionStatement
          ? statement.expression
          : null;
      final target = invocation is MethodInvocation && !invocation.isCascaded
          ? invocation.target?.toSource()
          : null;
      if (target == null || (receiver != null && target != receiver)) {
        _check(run);
        run = [];
        receiver = null;
        continue;
      }
      final uses = _useOf(invocation!);
      if (uses.isEmpty) {
        _check(run);
        run = [];
        receiver = null;
        continue;
      }
      receiver = target;
      run.addAll(uses);
    }
    _check(run);
    super.visitBlock(node);
  }

  /// Reports the first descending adjacent pair among the recognized entries.
  /// One report per run: a chain with three inversions has one mistake in it,
  /// and three squiggles would say the same thing three times.
  void _check(List<_Use> uses) {
    for (var i = 1; i < uses.length; i++) {
      final outer = uses[i - 1];
      final inner = uses[i];
      if (inner.order.rank >= outer.order.rank) continue;
      if (_ownedByTxRule(inner.name, outer.name)) continue;
      report(inner, outer);
      return;
    }
  }
}

/// The recognized `use(mw())` in [expression], or empty when it is not a
/// `use()` call, carries no single middleware argument, or names a middleware
/// with no known position.
///
/// An explicit `order:` argument is deliberate placement — the application
/// overriding what keta shipped — so the entry is dropped from the run rather
/// than checked against a position it was told not to occupy.
List<_Use> _useOf(Expression expression) {
  if (expression is! MethodInvocation || expression.methodName.name != 'use') {
    return const [];
  }
  // Exactly one argument, so a `use(m, order: ...)` — two arguments — drops out
  // here: an explicit position is deliberate placement, and checking it against
  // the one keta shipped would flag the override the application chose.
  final args = expression.argumentList.arguments;
  if (args.length != 1) return const [];
  final arg = args.first;
  if (arg is! MethodInvocation) return const [];
  final order = _positions[arg.methodName.name];
  if (order == null) return const [];
  return [_Use(arg.methodName.name, order, arg.offset, arg.length)];
}
