/// keta_lints — the contract-first toolchain: diagnostics with stable IDs, the
/// contract-drift document diff, and the scaffold code generator.
library;

export 'src/diagnostic.dart' show Diagnostic, diagnosticId;
export 'src/drift.dart' show contractDrift;
export 'src/generate.dart' show Scaffold, ScaffoldError, generateScaffold;
export 'src/yaml_plain.dart' show loadYamlDocument, yamlToPlain;
