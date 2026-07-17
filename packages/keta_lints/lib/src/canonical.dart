library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'canonical_shape.dart';
import 'diagnostic.dart';

/// Reports canonical-form problems on DTO-shaped classes in [source]:
///
/// - `keta_canonical_missing`: a DTO that lacks a `fromJson` factory or a
///   `toJson` method.
/// - `keta_canonical_drift`: a DTO whose `toJson`/`fromJson` keys do not match
///   its final field names.
/// - `keta_schema_drift`: a DTO whose `Schema` constant's `properties` do not
///   match its final field names, so the emitted OpenAPI would be wrong.
///
/// A class is a DTO by signal — it has a `Schema` constant, a `fromJson`, or a
/// `toJson` — never by the shape of its fields, so plain service/value classes
/// are never flagged. Purely syntactic; no resolution needed.
///
/// Every decision here — what counts as a DTO, whether a mapper is
/// hand-modified, and whether the fixer could actually act — is delegated to
/// [CanonicalClass] (canonical_shape.dart), the *same* recognizer the fixer
/// uses. That is deliberate: `check` must flag exactly what `fix` would change
/// and must never recommend a `fix` that would silently refuse the class.
List<Diagnostic> canonicalDiagnostics(
  String source, {
  String file = '<memory>',
}) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final context = CanonicalUnit.of(unit);
  final diagnostics = <Diagnostic>[];
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration) {
      _checkClass(declaration, context, file, diagnostics);
    }
  }
  return diagnostics;
}

void _checkClass(
  ClassDeclaration node,
  CanonicalUnit context,
  String file,
  List<Diagnostic> diagnostics,
) {
  // Not a canonical DTO at all — no signal, abstract/sealed, or a subclass
  // (whose inherited fields aren't derivable syntactically). The fixer ignores
  // these identically, so the check stays silent.
  final dto = CanonicalClass.of(node, context);
  if (dto == null) return;

  final className = dto.className;
  final nameToken = dto.nameToken;

  Diagnostic make(String rule, String message) => Diagnostic(
    rule: rule,
    message: message,
    file: file,
    scope: className,
    offset: nameToken.offset,
    length: nameToken.length,
  );

  // The recommendation clause every message ends with. It fires the same
  // finding regardless of fixability (a broken round-trip must be seen), but
  // only points at `dart run keta_lints:fix` when the fixer would actually act.
  // When [CanonicalClass.refusalReason] is non-null — a positional ctor, a
  // field type outside the canonical subset, a hand-modified sibling mapper —
  // recommending the fix would send the user to a command that refuses and
  // no-ops, so the clause names the blocker and tells them to do it by hand.
  // [fixVerb]/[handVerb] read naturally per subject ('materialize the mapper'
  // vs 'reconcile it by hand').
  String advise(String fixVerb, String handVerb) {
    final reason = dto.refusalReason;
    return reason == null
        ? 'run keta_lints:fix to $fixVerb'
        : '$handVerb by hand ($reason keeps keta_lints:fix from doing it)';
  }

  // --- missing mapper ------------------------------------------------------
  if (dto.fromJson == null || dto.toJson == null) {
    final side = dto.fromJson == null ? 'fromJson factory' : 'toJson method';
    diagnostics.add(
      make(
        'keta_canonical_missing',
        'class $className has final fields but no $side; '
            '${advise('materialize the canonical mapper', 'materialize it')}',
      ),
    );
    return;
  }

  // --- both mappers present ------------------------------------------------
  // A mapper the fixer can't recognize is hand-modified: its key set can't be
  // trusted, so it is neither verified nor reported — the same silence the
  // fixer honors by leaving it untouched. This is also where a spread /
  // collection-for / computed-key toJson lands (toJsonKeys returns null), so a
  // hand-authored literal is never misread as an incomplete key set.
  final jsonKeys = toJsonKeys(dto.toJson!);
  if (jsonKeys == null) return;
  if (!isCanonicalFromJson(dto.fromJson!, className)) return;

  // Drift is reported against the FULL final-field set (not the fixer's
  // resolvable subset): a broken round-trip is a real bug the user must see
  // even when a positional ctor or an exotic field type means the auto-fixer
  // will decline it — the same posture the mapper-drift check has always had.
  final fields = dto.allFinalFieldNames;
  final fromKeys = fromJsonKeys(dto.fromJson!);
  // Verify BOTH directions of the round-trip: toJson writes exactly the fields,
  // and fromJson reads exactly the fields. A half-done rename (fromJson still
  // reading the old key) round-trips broken but a toJson-only check misses it.
  final parts = [
    if (fields.difference(jsonKeys).isNotEmpty)
      'fields not in toJson: ${fields.difference(jsonKeys).join(', ')}',
    if (jsonKeys.difference(fields).isNotEmpty)
      'toJson keys not fields: ${jsonKeys.difference(fields).join(', ')}',
    if (fields.difference(fromKeys).isNotEmpty)
      'fields not read by fromJson: ${fields.difference(fromKeys).join(', ')}',
    if (fromKeys.difference(fields).isNotEmpty)
      'fromJson reads unknown keys: ${fromKeys.difference(fields).join(', ')}',
  ];
  if (parts.isNotEmpty) {
    diagnostics.add(
      make(
        'keta_canonical_drift',
        'class $className has drifted (${parts.join('; ')}); '
            '${advise('reconcile the mapper', 'reconcile it')}',
      ),
    );
  }

  // --- schema drift --------------------------------------------------------
  // The Schema constant is the source of the emitted OpenAPI document. If its
  // `properties` no longer match the fields, `check` was previously green while
  // `fix` would rewrite the Schema — CI shipped a wrong contract. Report it so
  // check flags exactly what fix reconciles. A distinct rule id (not
  // keta_canonical_drift) keeps the mapper and schema findings — and their
  // stable ids — separate when a class has drifted on both.
  final schema = context.schemas[className];
  if (schema != null) {
    final props = schemaPropertyNames(schema);
    if (!setEquals(props, fields)) {
      final schemaParts = [
        if (fields.difference(props).isNotEmpty)
          'fields not in schema: ${fields.difference(props).join(', ')}',
        if (props.difference(fields).isNotEmpty)
          'schema properties not fields: ${props.difference(fields).join(', ')}',
      ];
      diagnostics.add(
        make(
          'keta_schema_drift',
          'class $className Schema constant has drifted '
              '(${schemaParts.join('; ')}); '
              '${advise('reconcile the Schema', 'reconcile the Schema')}',
        ),
      );
    }
  }
}
