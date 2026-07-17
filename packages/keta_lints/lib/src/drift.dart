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
  void report(String scope, String message) => diagnostics.add(
    Diagnostic(
      rule: 'keta_contract_drift',
      message: message,
      file: file,
      scope: scope,
    ),
  );

  final oraclePaths = _paths(oracle, 'the contract', report);
  final shadowPaths = _paths(shadow, 'the code', report);

  for (final path in oraclePaths.keys) {
    final oracleOps = oraclePaths[path]!;
    final shadowOps = shadowPaths[path];
    if (shadowOps == null) {
      report(
        path,
        'contract has "$path" but the code does not; materialize the route skeleton',
      );
      continue;
    }
    for (final method in oracleOps.difference(shadowOps)) {
      report(
        '$method $path',
        'contract has "$method $path" but the code does not; add the handler',
      );
    }
  }
  for (final path in shadowPaths.keys) {
    final shadowOps = shadowPaths[path]!;
    final oracleOps = oraclePaths[path];
    if (oracleOps == null) {
      report(
        path,
        'the code serves "$path" but the contract omits it; document it or remove the route',
      );
      continue;
    }
    for (final method in shadowOps.difference(oracleOps)) {
      report(
        '$method $path',
        'the code serves "$method $path" but the contract omits it; document it or remove the route',
      );
    }
  }

  _schemaDrift(oracle, shadow, report);
  return diagnostics;
}

void _schemaDrift(
  Map<String, Object?> oracle,
  Map<String, Object?> shadow,
  void Function(String scope, String message) report,
) {
  final oracleSchemas = _schemas(oracle, 'the contract', report);
  final shadowSchemas = _schemas(shadow, 'the code', report);
  for (final name in oracleSchemas.keys) {
    final oracleProps = _propertyNames(oracleSchemas[name]!);
    final shadowSchema = shadowSchemas[name];
    if (shadowSchema == null) {
      report(
        'schema $name',
        'contract defines schema "$name" but the code does not; materialize the DTO',
      );
      continue;
    }
    final shadowProps = _propertyNames(shadowSchema);
    for (final field in oracleProps.difference(shadowProps)) {
      report(
        '$name.$field',
        'contract field "$name.$field" is missing from the code; add it to the DTO',
      );
    }
    for (final field in shadowProps.difference(oracleProps)) {
      report(
        '$name.$field',
        'the code has field "$name.$field" but the contract omits it; document it or remove it',
      );
    }
    // A field present on both sides can still have drifted in TYPE — a wire-
    // breaking change a name-only diff misses.
    final oracleFields = _properties(oracleSchemas[name]!);
    final shadowFields = _properties(shadowSchema);
    for (final field in oracleProps.intersection(shadowProps)) {
      final o = _typeSignature(oracleFields[field]!);
      final s = _typeSignature(shadowFields[field]!);
      if (o != s) {
        report(
          '$name.$field',
          'contract field "$name.$field" is $o but the code has $s; reconcile the type',
        );
      }
    }
    // required-set drift is likewise wire-relevant (optional vs required).
    final oracleReq = _requiredNames(oracleSchemas[name]!);
    final shadowReq = _requiredNames(shadowSchema);
    for (final field in oracleReq.difference(shadowReq)) {
      report(
        '$name.$field',
        'contract requires "$name.$field" but the code makes it optional',
      );
    }
    for (final field in shadowReq.difference(oracleReq)) {
      report(
        '$name.$field',
        'the code requires "$name.$field" but the contract makes it optional',
      );
    }
  }
  // Schemas the code defines but the contract omits.
  for (final name in shadowSchemas.keys) {
    if (!oracleSchemas.containsKey(name)) {
      report(
        'schema $name',
        'the code defines schema "$name" but the contract omits it; document it or remove the DTO',
      );
    }
  }
}

/// The operation-method set per path in [document], keyed by path. The oracle
/// half of this is EXTERNAL input, so a malformed `paths` mapping or a path
/// whose item is not an operations map is reported as descriptive drift and
/// skipped, never allowed to crash the CI gate with a bare `TypeError`. [label]
/// names the offending side ('the contract' / 'the code') in the message.
Map<String, Set<String>> _paths(
  Map<String, Object?> document,
  String label,
  void Function(String scope, String message) report,
) {
  final paths = document['paths'];
  if (paths == null) return const {};
  if (paths is! Map) {
    report(
      'paths',
      '$label "paths" is not a mapping (${paths.runtimeType}); fix the document',
    );
    return const {};
  }
  final result = <String, Set<String>>{};
  for (final entry in paths.entries) {
    final path = entry.key.toString();
    final item = entry.value;
    if (item is! Map) {
      report(
        path,
        '$label path "$path" is not an operations mapping '
            '(${item.runtimeType}); fix the document',
      );
      continue;
    }
    result[path] = {
      for (final method in item.keys)
        if (_httpMethods.contains(method.toString())) method.toString(),
    };
  }
  return result;
}

/// The named component schemas in [document]. As with [_paths], the oracle side
/// is EXTERNAL, so a schema entry that is not an object is reported as
/// descriptive drift and skipped rather than crashing on a bare cast.
Map<String, Map<String, Object?>> _schemas(
  Map<String, Object?> document,
  String label,
  void Function(String scope, String message) report,
) {
  final components = document['components'];
  final schemas = components is Map ? components['schemas'] : null;
  if (schemas is! Map) return {};
  final result = <String, Map<String, Object?>>{};
  for (final entry in schemas.entries) {
    final name = entry.key.toString();
    final value = entry.value;
    if (value is! Map) {
      report(
        'schema $name',
        '$label schema "$name" is not an object (${value.runtimeType}); '
            'fix the document',
      );
      continue;
    }
    result[name] = value.cast<String, Object?>();
  }
  return result;
}

Set<String> _propertyNames(Map<String, Object?> schema) {
  final properties = schema['properties'];
  return properties is Map
      ? {for (final key in properties.keys) key.toString()}
      : <String>{};
}

Map<String, Map<String, Object?>> _properties(Map<String, Object?> schema) {
  final properties = schema['properties'];
  if (properties is! Map) return const {};
  return {
    for (final entry in properties.entries)
      entry.key.toString(): (entry.value as Map).cast<String, Object?>(),
  };
}

Set<String> _requiredNames(Map<String, Object?> schema) {
  final required = schema['required'];
  return required is List
      ? {for (final v in required) v.toString()}
      : <String>{};
}

/// A comparable, human-readable signature of a property's type: its `$ref`, or
/// its `type` (with array item type and enum values folded in) — enough to
/// catch a wire-breaking type change between two schemas of the same field.
String _typeSignature(Map<String, Object?> prop) {
  final ref = prop[r'$ref'];
  if (ref is String) return ref;
  final type = prop['type']?.toString() ?? 'any';
  if (type == 'array' && prop['items'] is Map) {
    return 'array<${_typeSignature((prop['items'] as Map).cast<String, Object?>())}>';
  }
  final values = prop['enum'];
  if (values is List) return '$type enum[${values.join('|')}]';
  return type;
}

const _httpMethods = {
  'get',
  'post',
  'put',
  'delete',
  'patch',
  'head',
  'options',
};
