/// The analyzer-plugin surface for keta_lints: thin [AnalysisRule] adapters that
/// run the per-file diagnostic functions (the same pure functions the
/// `keta_lints:check` CLI runs) over a compilation unit and report each finding
/// where the source points.
///
/// The IDE and the CLI therefore agree by construction: both call the same
/// function, so the reported message body and the stable id (16 hex of
/// `sha256(file|scope|rule)`) are identical for the same source and path. Each
/// reported message is `[<id>] <message>`, carrying the correlation id the spec
/// requires; the analyzer shows the keta rule name as the diagnostic code.
///
/// Cross-file checks (route conflicts across files, contract drift) stay
/// CLI-authoritative per the spec — a plugin sees one file at a time — so they
/// are deliberately absent here.
library;

import 'package:analyzer/analysis_rule/analysis_rule.dart';
import 'package:analyzer/analysis_rule/rule_context.dart';
import 'package:analyzer/analysis_rule/rule_visitor_registry.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/error/error.dart';

import '../canonical.dart';
import '../diagnostic.dart';
import '../internal_await.dart';
import '../package_path.dart';
import '../query_lint.dart';
import '../routes_lint.dart';
import '../tx_order.dart';

// The lint codes, one per keta rule id. Each is a top-level `const` so a single
// instance exists — a functional requirement for `// ignore:` suppression to
// match. The problem message is the placeholder `{0}`; the full `[id] message`
// is passed as the argument at report time.
const _paramUnknown = LintCode(
  'keta_param_unknown',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _captureUnused = LintCode(
  'keta_capture_unused',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _queryUndeclared = LintCode(
  'keta_query_undeclared',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _queryDrift = LintCode(
  'keta_query_drift',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _canonicalMissing = LintCode(
  'keta_canonical_missing',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _canonicalDrift = LintCode(
  'keta_canonical_drift',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _typeDrift = LintCode(
  'keta_type_drift',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _schemaDrift = LintCode(
  'keta_schema_drift',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _txOutsideRecover = LintCode(
  'keta_tx_outside_recover',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);
const _internalAwait = LintCode(
  'keta_internal_await',
  '{0}',
  severity: DiagnosticSeverity.WARNING,
);

/// Shared base: walk the compilation unit once, run [analyze] over its source,
/// and report each [Diagnostic] at its `(offset, length)` under the matching
/// lint code.
abstract class _KetaRule extends MultiAnalysisRule {
  _KetaRule({required super.name, required super.description});

  /// Maps a keta rule id (e.g. `keta_param_unknown`) to its [LintCode].
  Map<String, LintCode> get _codes;

  /// Runs the rule's per-file diagnostic over the already-parsed [unit],
  /// keyed by the package-relative [file]. Each rule feeds the analyzer's own
  /// parsed [RuleContextUnit.unit] to the matching `…Unit` function, so no rule
  /// re-parses source the analyzer has already parsed.
  List<Diagnostic> _analyze(RuleContextUnit unit, String file);

  @override
  List<DiagnosticCode> get diagnosticCodes => _codes.values.toList();

  @override
  void registerNodeProcessors(
    RuleVisitorRegistry registry,
    RuleContext context,
  ) {
    registry.addCompilationUnit(this, _KetaVisitor(this, context));
  }

  void _run(RuleContext context) {
    final unit = context.currentUnit;
    if (unit == null) return;
    // Key the stable id on the package-relative path, exactly as the CLI does,
    // so the same finding carries the same `[id]` in the IDE and on CI.
    final file = packageRelativePath(unit.file.path);
    for (final d in _analyze(unit, file)) {
      final code = _codes[d.rule];
      if (code == null) continue;
      reportAtOffset(
        d.offset,
        d.length,
        diagnosticCode: code,
        arguments: ['[${d.id}] ${d.message}'],
      );
    }
  }
}

class _KetaVisitor extends SimpleAstVisitor<void> {
  _KetaVisitor(this.rule, this.context);
  final _KetaRule rule;
  final RuleContext context;

  @override
  void visitCompilationUnit(CompilationUnit node) => rule._run(context);
}

/// `keta_param_unknown` + `keta_capture_unused` — string-route param/capture
/// drift.
class KetaRouteRule extends _KetaRule {
  KetaRouteRule()
    : super(
        name: 'keta_route',
        description:
            'A c.param name must be a capture in the route template, and every '
            'capture must be read.',
      );

  @override
  List<Diagnostic> _analyze(RuleContextUnit unit, String file) =>
      routeDiagnosticsUnit(unit.unit, file: file);

  @override
  Map<String, LintCode> get _codes => const {
    'keta_param_unknown': _paramUnknown,
    'keta_capture_unused': _captureUnused,
  };
}

/// `keta_query_undeclared` + `keta_query_drift` — query accessor vs
/// `RouteDoc(query: …)` drift.
class KetaQueryRule extends _KetaRule {
  KetaQueryRule()
    : super(
        name: 'keta_query',
        description:
            'A query accessor must match a declared RouteDoc query param, and a '
            'required param must be read with c.query, not tryQuery.',
      );

  @override
  List<Diagnostic> _analyze(RuleContextUnit unit, String file) =>
      queryDiagnosticsUnit(unit.unit, file: file);

  @override
  Map<String, LintCode> get _codes => const {
    'keta_query_undeclared': _queryUndeclared,
    'keta_query_drift': _queryDrift,
  };
}

/// `keta_canonical_missing` + `keta_canonical_drift` + `keta_type_drift` +
/// `keta_schema_drift` — a DTO's mapper is absent, its mapper keys have drifted
/// from its field set, a fromJson cast has drifted from a field's declared type,
/// or its `Schema` constant has drifted from its field set (a wrong OpenAPI
/// document).
class KetaCanonicalRule extends _KetaRule {
  KetaCanonicalRule()
    : super(
        name: 'keta_canonical',
        description:
            'A DTO must carry fromJson/toJson and a Schema whose keys match its '
            'final fields.',
      );

  @override
  List<Diagnostic> _analyze(RuleContextUnit unit, String file) =>
      canonicalDiagnosticsUnit(unit.unit, file: file);

  @override
  Map<String, LintCode> get _codes => const {
    'keta_canonical_missing': _canonicalMissing,
    'keta_canonical_drift': _canonicalDrift,
    'keta_type_drift': _typeDrift,
    'keta_schema_drift': _schemaDrift,
  };
}

/// `keta_tx_outside_recover` — `use(tx())` registered outside `use(recover())`.
class KetaTxOrderRule extends _KetaRule {
  KetaTxOrderRule()
    : super(
        name: 'keta_tx_outside_recover',
        description:
            'Register recover() before tx() so a failed request rolls back '
            'rather than commits.',
      );

  @override
  List<Diagnostic> _analyze(RuleContextUnit unit, String file) =>
      txOrderDiagnosticsUnit(unit.unit, file: file);

  @override
  Map<String, LintCode> get _codes => const {
    'keta_tx_outside_recover': _txOutsideRecover,
  };
}

/// `keta_internal_await` — `await` on the framework's synchronous path. Opt-in
/// (registered as a lint), because it is meaningful only over keta's own
/// composition modules, not consumer code.
class KetaInternalAwaitRule extends _KetaRule {
  KetaInternalAwaitRule()
    : super(
        name: 'keta_internal_await',
        description:
            'await defeats the Future-free synchronous path; use chain()/guard() '
            'or justify it with // keta:allow-await.',
      );

  @override
  List<Diagnostic> _analyze(RuleContextUnit unit, String file) =>
      internalAwaitDiagnosticsUnit(unit.unit, unit.content, file: file);

  @override
  Map<String, LintCode> get _codes => const {
    'keta_internal_await': _internalAwait,
  };
}
