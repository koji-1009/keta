library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

import 'diagnostic.dart';

/// Reports `keta_key_inline`: a `Key(...)`/`Key<T>(...)` constructed directly
/// as the key argument to a `Context` accessor — `c.get(Key(...))`,
/// `c.tryGet(Key(...))`, or `c.set(Key(...), value)`.
///
/// keta's `Key<T>` (`packages/keta/lib/src/context.dart`) backs `RequestCtx`'s
/// per-request store, a `Map<Key<Object?>, Object?>`, and carries no `==`/
/// `hashCode` override, so it compares by the default identity — confirmed by
/// its own doc comment: "Keys compare by identity, so a `const` constructor is
/// forbidden: const canonicalization would fuse separate declarations into one
/// instance and collide." A `Key` built inline at the call site is therefore a
/// fresh, never-shared instance every time that line runs: `c.set(Key('x'),
/// v)` binds `v` under *that* instance, and any other call site — including
/// another `Key('x')` with the identical name — constructs a *different*
/// instance that can never `==` it. The bound value is then unreachable:
/// `c.get` throws `StateError` (no value bound for it), and `c.tryGet` just
/// silently returns null. The fix is to declare the key exactly once, as a
/// top-level or static field, and share that one instance across every read
/// and write. (`Key`'s constructor is not `const` — see above — so the field
/// must be `final`, not `const`.)
///
/// Single-file and syntactic, matching the precision of the sibling query/
/// route/tx-order rules: it flags a `Key`/`Key<T>` instantiation appearing
/// directly as the get/tryGet/set key argument on a dotted call
/// (`<receiver>.get(...)` etc.), without resolving whether the receiver is
/// really a `Context` — the sibling rules take the same syntactic shortcut for
/// their own accessors. It does NOT flag a key built inline and then bound to
/// a local before use (`final k = Key('x'); c.get(k);`): the local is still a
/// fresh instance each time its enclosing scope runs, so it is a real (if
/// rarer) instance of the same bug, but catching it needs data-flow analysis
/// this syntactic rule deliberately does not attempt — a known non-goal.
///
/// The [String] entrypoint parses [source] (the CLI path); the plugin holds a
/// parsed unit and calls [keyDiagnosticsUnit], so it never re-parses.
List<Diagnostic> keyDiagnostics(String source, {String file = '<memory>'}) =>
    keyDiagnosticsUnit(
      parseString(content: source, throwIfDiagnostics: false).unit,
      file: file,
    );

/// [keyDiagnostics] over an already-parsed [unit].
List<Diagnostic> keyDiagnosticsUnit(
  CompilationUnit unit, {
  String file = '<memory>',
}) {
  final diagnostics = <Diagnostic>[];
  unit.accept(_KeyVisitor(file, diagnostics));
  return diagnostics;
}

const _accessors = {'get', 'tryGet', 'set'};

class _KeyVisitor extends RecursiveAstVisitor<void> {
  _KeyVisitor(this.file, this.diagnostics);
  final String file;
  final List<Diagnostic> diagnostics;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_accessors.contains(node.methodName.name) && node.target != null) {
      final args = node.argumentList.arguments;
      // For get/tryGet the key is the sole argument; for set it is the first
      // of two (Key<T> key, T value) — either way it is args.first.
      // `.argumentExpression` unwraps a NamedArgument to its value; a
      // positional argument (the only form get/tryGet/set take) is already an
      // Expression and returns itself.
      final keyArg = args.isEmpty ? null : args.first.argumentExpression;
      if (keyArg != null && _isKeyConstruction(keyArg)) {
        diagnostics.add(
          Diagnostic(
            rule: 'keta_key_inline',
            message:
                'a Key constructed inline here can never match a value stored '
                'under a different Key instance — Key compares by identity, '
                'and this call site mints a fresh, unshared instance every '
                'time it runs; declare the key once as a top-level or static '
                'field and share that one instance for every get/tryGet/set',
            file: file,
            scope: '${node.methodName.name}@${keyArg.offset}',
            offset: keyArg.offset,
            length: keyArg.length,
          ),
        );
      }
    }
    super.visitMethodInvocation(node);
  }
}

/// Whether [e] is a `Key(...)`/`Key<T>(...)` instantiation.
///
/// A constructor call without `const`/`new` parses as a [MethodInvocation]
/// both unresolved (the CLI's [parseString] path) and, empirically, still as
/// a [MethodInvocation] once the plugin's unit is resolved — this analyzer
/// version does not rewrite it into an [InstanceCreationExpression]. Both
/// node shapes are still checked here, matching the belt-and-suspenders
/// duality [query_lint]'s `_ctor` uses for `RouteDoc`/`QueryParam`, so the
/// rule keeps working if that ever changes.
bool _isKeyConstruction(Expression e) => switch (e) {
  InstanceCreationExpression(:final constructorName) =>
    constructorName.type.name.lexeme == 'Key',
  MethodInvocation(:final methodName, target: null) => methodName.name == 'Key',
  _ => false,
};
