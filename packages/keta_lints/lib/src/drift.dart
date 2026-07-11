library;

import 'diagnostic.dart';

/// Compares the externally-supplied contract [oracle] with the OpenAPI document
/// the code emits ([shadow]) and reports every divergence as a
/// `keta_contract_drift` diagnostic. Comparison is a pure document diff, so it
/// needs no access to the running route table.
///
/// Endpoints and fields present in the oracle but missing from the shadow are
/// flagged for additive materialization; those present only in the shadow are
/// flagged as undocumented.
List<Diagnostic> contractDrift(
  Map<String, Object?> oracle,
  Map<String, Object?> shadow, {
  String file = 'openapi.yaml',
}) {
  final diagnostics = <Diagnostic>[];
  void report(String scope, String message) => diagnostics.add(Diagnostic(
        rule: 'keta_contract_drift',
        message: message,
        file: file,
        scope: scope,
      ));

  final oraclePaths = _paths(oracle);
  final shadowPaths = _paths(shadow);

  for (final path in oraclePaths.keys) {
    final oracleOps = oraclePaths[path]!;
    final shadowOps = shadowPaths[path];
    if (shadowOps == null) {
      report(path,
          'contract has "$path" but the code does not; materialize the route skeleton');
      continue;
    }
    for (final method in oracleOps.difference(shadowOps)) {
      report('$method $path',
          'contract has "$method $path" but the code does not; add the handler');
    }
  }
  for (final path in shadowPaths.keys) {
    final shadowOps = shadowPaths[path]!;
    final oracleOps = oraclePaths[path];
    if (oracleOps == null) {
      report(path,
          'the code serves "$path" but the contract omits it; document it or remove the route');
      continue;
    }
    for (final method in shadowOps.difference(oracleOps)) {
      report('$method $path',
          'the code serves "$method $path" but the contract omits it; document it or remove the route');
    }
  }

  _schemaDrift(oracle, shadow, report);
  return diagnostics;
}

void _schemaDrift(Map<String, Object?> oracle, Map<String, Object?> shadow,
    void Function(String scope, String message) report) {
  final oracleSchemas = _schemas(oracle);
  final shadowSchemas = _schemas(shadow);
  for (final name in oracleSchemas.keys) {
    final oracleProps = _propertyNames(oracleSchemas[name]!);
    final shadowSchema = shadowSchemas[name];
    if (shadowSchema == null) {
      report('schema $name',
          'contract defines schema "$name" but the code does not; materialize the DTO');
      continue;
    }
    final shadowProps = _propertyNames(shadowSchema);
    for (final field in oracleProps.difference(shadowProps)) {
      report('$name.$field',
          'contract field "$name.$field" is missing from the code; add it to the DTO');
    }
    for (final field in shadowProps.difference(oracleProps)) {
      report('$name.$field',
          'the code has field "$name.$field" but the contract omits it; document it or remove it');
    }
  }
}

Map<String, Set<String>> _paths(Map<String, Object?> document) {
  final paths = (document['paths'] as Map?) ?? const {};
  return {
    for (final entry in paths.entries)
      entry.key.toString(): {
        for (final method in (entry.value as Map).keys)
          if (_httpMethods.contains(method.toString())) method.toString(),
      },
  };
}

Map<String, Map<String, Object?>> _schemas(Map<String, Object?> document) {
  final components = document['components'];
  final schemas = components is Map ? components['schemas'] : null;
  if (schemas is! Map) return {};
  return {
    for (final entry in schemas.entries)
      entry.key.toString(): (entry.value as Map).cast<String, Object?>(),
  };
}

Set<String> _propertyNames(Map<String, Object?> schema) {
  final properties = schema['properties'];
  return properties is Map
      ? {for (final key in properties.keys) key.toString()}
      : <String>{};
}

const _httpMethods = {'get', 'post', 'put', 'delete', 'patch', 'head', 'options'};
