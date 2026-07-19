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
///
/// The [String] entrypoint parses [source] (the CLI path); the plugin holds a
/// parsed unit and its content and calls [internalAwaitDiagnosticsUnit], so it
/// never re-parses. The raw [source] is still needed on both paths to read the
/// `// keta:allow-await` opt-out off the awaiting line and the line above it.
List<Diagnostic> internalAwaitDiagnostics(
  String source, {
  String file = '<memory>',
}) => internalAwaitDiagnosticsUnit(
  parseString(content: source, throwIfDiagnostics: false).unit,
  source,
  file: file,
);

/// [internalAwaitDiagnostics] over an already-parsed [unit], taking the raw
/// [source] alongside it for the line-based `// keta:allow-await` scan.
List<Diagnostic> internalAwaitDiagnosticsUnit(
  CompilationUnit unit,
  String source, {
  String file = '<memory>',
}) {
  final lineInfo = unit.lineInfo;
  final lines = source.split('\n');
  final diagnostics = <Diagnostic>[];

  void report(int offset, int length) {
    final location = lineInfo.getLocation(offset);
    final line = location.lineNumber; // 1-based
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
        // Two awaits on one line share a line number, so the id keys on
        // line:column, not the line alone. The column is stable against edits
        // elsewhere in the file (unlike a raw byte offset, which shifts on any
        // earlier insertion) while still separating same-line awaits.
        scope: 'L$line:C${location.columnNumber}',
        offset: offset,
        length: length,
      ),
    );
  }

  unit.accept(_AwaitVisitor(report));
  return diagnostics;
}

class _AwaitVisitor extends RecursiveAstVisitor<void> {
  _AwaitVisitor(this.report);
  final void Function(int offset, int length) report;

  @override
  void visitAwaitExpression(AwaitExpression node) {
    report(node.awaitKeyword.offset, node.awaitKeyword.length);
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    final awaitKeyword = node.awaitKeyword;
    if (awaitKeyword != null) {
      report(awaitKeyword.offset, awaitKeyword.length);
    }
    super.visitForStatement(node);
  }
}
