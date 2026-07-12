/// keta_lints — the contract-first toolchain: diagnostics with stable IDs, the
/// contract-drift document diff, and the scaffold code generator.
library;

export 'src/canonical.dart' show canonicalDiagnostics;
export 'src/diagnostic.dart' show Diagnostic, diagnosticId;
export 'src/drift.dart' show contractDrift;
export 'src/fix.dart' show applyCanonicalFix;
export 'src/generate.dart' show Scaffold, ScaffoldError, generateScaffold;
export 'src/internal_await.dart' show internalAwaitDiagnostics;
export 'src/routes_lint.dart' show routeDiagnostics;
export 'src/tx_order.dart' show txOrderDiagnostics;
export 'src/yaml_plain.dart' show loadYamlDocument, yamlToPlain;
