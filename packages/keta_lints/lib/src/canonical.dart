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
///
/// The [String] entrypoint parses [source] (the CLI path); the analyzer plugin
/// holds a parsed unit and calls [canonicalDiagnosticsUnit] directly, so it
/// never re-parses a file the analyzer already parsed.
List<Diagnostic> canonicalDiagnostics(
  String source, {
  String file = '<memory>',
}) => canonicalDiagnosticsUnit(
  parseString(content: source, throwIfDiagnostics: false).unit,
  file: file,
);

/// [canonicalDiagnostics] over an already-parsed [unit].
List<Diagnostic> canonicalDiagnosticsUnit(
  CompilationUnit unit, {
  String file = '<memory>',
}) {
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

  // The Schema clause uses its OWN fixability verdict: reconciling the Schema is
  // independent of the mappers and the ctor (fix.dart repairs it even when it
  // refuses the mappers), so a positional ctor / hand-modified mapper must NOT
  // steer the user away from the fix here — only an unresolvable field type,
  // which is the sole thing that blocks Schema regeneration, may.
  String adviseSchema() {
    final reason = dto.schemaRefusalReason;
    return reason == null
        ? 'run keta_lints:fix to reconcile the Schema'
        : 'reconcile the Schema by hand '
              '($reason keeps keta_lints:fix from doing it)';
  }

  // --- schema drift (checked independently of the mappers) -----------------
  // The Schema constant is the source of the emitted OpenAPI document. Its
  // `properties` are compared to the fields with no regard for the mappers'
  // shape — and fix reconciles it even on a class whose (hand-modified/spread)
  // mappers it refuses — so this check must run BEFORE the mapper early-returns
  // below, or a spread toJson would suppress a stale-Schema finding entirely
  // (CI shipping a wrong contract). A distinct rule id (not keta_canonical_drift)
  // keeps the mapper and schema findings — and their stable ids — separate when
  // a class has drifted on both.
  final schema = context.schemas[className];
  if (schema != null) {
    final props = schemaPropertyNames(schema);
    final fields = dto.allFinalFieldNames;
    if (!setEquals(props, fields)) {
      final missing = fields.difference(props);
      final extra = props.difference(fields);
      final schemaParts = [
        if (missing.isNotEmpty) 'fields not in schema: ${missing.join(', ')}',
        if (extra.isNotEmpty)
          'schema properties not fields: ${extra.join(', ')}',
      ];
      diagnostics.add(
        make(
          'keta_schema_drift',
          'class $className Schema constant has drifted '
              '(${schemaParts.join('; ')}); ${adviseSchema()}',
        ),
      );
    }
  }

  // --- missing mapper ------------------------------------------------------
  if (dto.fromJson == null || dto.toJson == null) {
    final side = dto.fromJson == null ? 'fromJson factory' : 'toJson method';
    // When one mapper is missing but the OTHER (present) one has itself
    // drifted, a single fix run rewrites BOTH — so name both axes rather than
    // only the missing side, which would under-report what fix touches.
    final sibling = _presentMapperDrifted(dto, className)
        ? ' (its ${dto.fromJson == null ? 'toJson' : 'fromJson'} has also '
              'drifted, so the fix rewrites both)'
        : '';
    diagnostics.add(
      make(
        'keta_canonical_missing',
        'class $className has final fields but no $side$sibling; '
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
  final jsonKeys = toJsonKeys(dto.toJson!, dto.allFinalFieldNames);
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

  // --- type drift ----------------------------------------------------------
  // A field whose declared type changed while its fromJson cast lagged (the
  // `field: json['key'] as T` shape) round-trips through the WRONG runtime type
  // — a `String` field still cast `as int` throws at parse, an `int?` field
  // cast `as int` throws on an absent key. This axis is orthogonal to the key
  // set (keys can match while a type drifts), so it carries its own rule id,
  // keeping its stable id separate when a class drifts on both. It fires only
  // for a fixable class: the fixer regenerates fromJson from the field types,
  // so whatever type drift is flagged here its whole-fromJson rewrite repairs —
  // check/fix symmetry by construction. (On a non-fixable class the recommended
  // action would be a no-op, so we stay silent, exactly as elsewhere.)
  // The enum-accessor axis rides here too (same rule id, same fixability gate):
  // an enum mapper is a wrapped call, so a wrong accessor — `values.byName`/
  // `.name` on an *enhanced* enum whose wire strings differ from its names —
  // slips past both the key-set diff and the bare-cast [typeDrifts], round-trips
  // through the wrong vocabulary, and silently breaks the wire contract. It IS a
  // type-contract drift, so it reports under keta_type_drift; the fix folds each
  // side into its member's drift flag, so whatever this flags, fix repairs.
  if (dto.isFixable) {
    final castDrifts = dto.typeDrifts;
    final enumDrift = dto.enumAccessorDrifts;
    final parts = [
      for (final d in castDrifts)
        '${d.field}: fromJson casts as ${d.cast} but the field is ${d.declared}',
      for (final f in enumDrift.fromJson)
        '$f: fromJson uses the wrong enum accessor for its wire mapping',
      for (final f in enumDrift.toJson)
        '$f: toJson uses the wrong enum accessor for its wire mapping',
    ];
    if (parts.isNotEmpty) {
      diagnostics.add(
        make(
          'keta_type_drift',
          'class $className has a mapper that disagrees with its field type '
              '(${parts.join('; ')}); '
              '${advise('reconcile the mapper', 'reconcile it')}',
        ),
      );
    }
  }
}

/// When exactly one mapper is present, whether that present mapper has itself
/// drifted (a key-set, cast, or enum-accessor mismatch the fixer would repair
/// in the same run that materializes the missing one). Mirrors the fixer's
/// per-member drift predicates so the missing-mapper message names every axis
/// the fix touches. A hand-modified present mapper (unrecognizable key set /
/// non-canonical fromJson) is left untouched by the fixer, so it does not count.
bool _presentMapperDrifted(CanonicalClass dto, String className) {
  final fields = dto.allFinalFieldNames;
  final enumDrift = dto.enumAccessorDrifts;
  if (dto.fromJson == null && dto.toJson != null) {
    final keys = toJsonKeys(dto.toJson!, fields);
    if (keys == null) return false; // hand-modified — fixer leaves it
    return !setEquals(keys, fields) || enumDrift.toJson.isNotEmpty;
  }
  if (dto.toJson == null && dto.fromJson != null) {
    if (!isCanonicalFromJson(dto.fromJson!, className)) return false;
    return !setEquals(fromJsonKeys(dto.fromJson!), fields) ||
        dto.typeDrifts.isNotEmpty ||
        enumDrift.fromJson.isNotEmpty;
  }
  return false; // both missing: nothing else to rewrite
}
