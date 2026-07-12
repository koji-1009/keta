library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';

/// Flags `await` (and `await for`) in framework composition code, which would
/// defeat the Future-free synchronous path. This is the mechanical guard for
/// the is-Future execution style: run it over the composition modules (chain,
/// middleware, dispatch).
///
/// A genuine I/O boundary can opt out with a `// keta:allow-await` comment on
/// the awaiting line or the line above it.
List<Diagnostic> internalAwaitDiagnostics(
  String source, {
  String file = '<memory>',
}) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  final lineInfo = result.lineInfo;
  final lines = source.split('\n');
  final diagnostics = <Diagnostic>[];

  void report(int offset) {
    final line = lineInfo.getLocation(offset).lineNumber; // 1-based
    final current = line <= lines.length ? lines[line - 1] : '';
    final previous = line >= 2 ? lines[line - 2] : '';
    if (current.contains('keta:allow-await') ||
        previous.contains('keta:allow-await')) {
      return;
    }
    diagnostics.add(
      Diagnostic(
        rule: 'keta_internal_await',
        message:
            'await on line $line defeats the synchronous path; use '
            'chain()/guard(), or justify it with // keta:allow-await',
        file: file,
        scope: 'L$line',
      ),
    );
  }

  result.unit.accept(_AwaitVisitor(report));
  return diagnostics;
}

class _AwaitVisitor extends RecursiveAstVisitor<void> {
  _AwaitVisitor(this.report);
  final void Function(int offset) report;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    report(node.awaitKeyword.offset);
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    final awaitKeyword = node.awaitKeyword;
    if (awaitKeyword != null) report(awaitKeyword.offset);
    super.visitForStatement(node);
  }
}
