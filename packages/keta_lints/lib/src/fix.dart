library;

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

import 'canonical_shape.dart';
import 'dart_literal.dart';

/// Applies the canonical-form repair to [source].
///
/// For every DTO-shaped class it regenerates the canonical members — `fromJson`,
/// `toJson`, and the matching `Schema` constant — **whole**, from the desired
/// state (the field set), and atomically replaces each member's source range.
/// Whole-member regeneration (rather than per-field surgery) makes the edits
/// non-overlapping by construction, so removing several fields, renaming the
/// sole field, or repairing a half-missing pair can't corrupt the source.
///
/// Only the member(s) that actually drifted are regenerated (D-2): a schema-only
/// drift never touches the mappers, a fromJson cast drift never rewrites toJson,
/// and so on — so a non-drifted member, with any inline comments it holds, is
/// left byte-for-byte identical. A leading `///` doc comment on a regenerated
/// member is preserved regardless; only inline comments inside the one drifted
/// member are lost, which is unavoidable when its body is what changed. The
/// `Schema` constant keeps every existing per-property definition (enums,
/// formats) verbatim and re-derives `$ref`/`deps` from one model.
///
/// Which classes are in scope — and which are left untouched because the fixer
/// can't safely act (a positional ctor, an unresolvable field type, a
/// hand-modified mapper, an `extends` clause, abstract/sealed) — is decided by
/// [CanonicalClass] in canonical_shape.dart, the exact same recognizer the
/// `check` diagnostic consults, so the two never disagree about what changes.
String applyCanonicalFix(String source) {
  final unit = parseString(content: source, throwIfDiagnostics: false).unit;
  final context = CanonicalUnit.of(unit);

  final edits = <_Edit>[];
  for (final declaration in unit.declarations) {
    if (declaration is ClassDeclaration) {
      _fixClass(declaration, context, source, edits);
    }
  }
  return _applyEdits(source, edits);
}

class _Edit {
  _Edit(this.start, this.end, this.replacement);
  final int start;
  final int end;
  final String replacement;
}

String _applyEdits(String source, List<_Edit> edits) {
  edits.sort((a, b) => b.start.compareTo(a.start));
  // Invariant: edits never overlap (whole-member/whole-initializer ranges).
  for (var i = 0; i + 1 < edits.length; i++) {
    if (edits[i].start < edits[i + 1].end) {
      throw StateError('overlapping canonical fix edits');
    }
  }
  var result = source;
  for (final edit in edits) {
    result = result.replaceRange(edit.start, edit.end, edit.replacement);
  }
  return result;
}

void _fixClass(
  ClassDeclaration node,
  CanonicalUnit context,
  String source,
  List<_Edit> edits,
) {
  final dto = CanonicalClass.of(node, context);
  if (dto == null) return;
  // Every reason the fixer must not touch a class — an unresolvable field type,
  // a positional ctor, a hand-modified/spread-carrying mapper — is folded into
  // this one verdict, shared with the `check` diagnostic so both agree.
  if (!dto.isFixable) return;

  final className = dto.className;
  final fields = dto.fields;
  final fromJson = dto.fromJson;
  final toJson = dto.toJson;
  final fieldNames = dto.fieldNames;
  final schema = context.schemas[className];

  // D-2: decide drift PER MEMBER, and regenerate ONLY the member(s) that
  // actually drifted, so a non-drifted member is left byte-for-byte untouched
  // and its inline comments survive. Previously any drift rewrote fromJson,
  // toJson, AND the Schema wholesale — a schema-only drift silently reformatted
  // both mappers, a fromJson cast drift rewrote toJson, and so on. Each axis is
  // now independent:
  //
  //  * fromJson drifts when it is missing, reads a key set other than the
  //    fields, OR carries a stale `as T` cast (type drift — invisible to a
  //    key-set diff, and repaired by regenerating fromJson from the field
  //    types, which is what keeps check/fix symmetry for keta_type_drift).
  //  * toJson drifts when it is missing or writes a key set other than the
  //    fields.
  //  * the Schema drifts when its `properties` key set differs from the fields.
  //
  // The `!` on toJsonKeys is safe: isFixable guarantees a present toJson is a
  // recognizable key set (else it would have been refused as hand-modified).
  // Regenerating a drifted member is still whole-member (atomic, non-
  // overlapping); only the comments INSIDE that one member are lost, which is
  // accepted since its body is exactly what changed. Leading doc comments and
  // metadata are preserved for every regenerated member (see [member]).
  final fromJsonDrifted =
      fromJson == null ||
      !setEquals(fromJsonKeys(fromJson), fieldNames) ||
      dto.typeDrifts.isNotEmpty;
  final toJsonDrifted =
      toJson == null || !setEquals(toJsonKeys(toJson)!, fieldNames);
  final schemaDrifted =
      schema != null && !setEquals(schemaPropertyNames(schema), fieldNames);
  if (!fromJsonDrifted && !toJsonDrifted && !schemaDrifted) {
    return; // already canonical.
  }

  final insertions = <String>[];
  void member(Declaration? existing, String generated) {
    if (existing == null) {
      insertions.add(generated);
    } else {
      final start = existing.firstTokenAfterCommentAndMetadata.offset;
      edits.add(_Edit(start, existing.end, generated.trimLeft()));
    }
  }

  if (fromJsonDrifted) member(fromJson, _fromJsonSource(className, fields));
  if (toJsonDrifted) member(toJson, _toJsonSource(fields));
  if (insertions.isNotEmpty) {
    final at = node.body.end - 1; // before the class's closing brace
    edits.add(_Edit(at, at, '\n${insertions.join('\n\n')}\n'));
  }
  if (schemaDrifted) {
    edits.add(
      _Edit(
        schema.offset,
        schema.end,
        _schemaSource(className, fields, schema, source),
      ),
    );
  }
}

// --- schema constant ------------------------------------------------------

/// Regenerates the whole `Schema(...)` initializer, preserving each existing
/// property definition verbatim (so enums/formats survive), preserving any
/// other top-level schema key (`description`, `additionalProperties`, …), and
/// re-deriving `required` and `deps` from the field model.
String _schemaSource(
  String className,
  List<CanonicalField> fields,
  Expression init,
  String source,
) {
  final map = schemaMap(init);
  final props = map == null ? null : propertiesLiteral(map);
  final existing = <String, String>{};
  if (props != null) {
    for (final e in props.elements) {
      if (e is MapLiteralEntry && e.key is SimpleStringLiteral) {
        existing[(e.key as SimpleStringLiteral).value] = source.substring(
          e.value.offset,
          e.value.end,
        );
      }
    }
  }
  // Preserve top-level keys the regeneration doesn't own (so a `description` or
  // `additionalProperties` is not silently dropped), verbatim and in order.
  final extras = <String>[];
  const owned = {'type', 'required', 'properties'};
  if (map != null) {
    for (final e in map.elements) {
      if (e is MapLiteralEntry && e.key is SimpleStringLiteral) {
        final key = (e.key as SimpleStringLiteral).value;
        if (owned.contains(key)) continue;
        extras.add(source.substring(e.key.offset, e.value.end));
      }
    }
  }

  final properties = [
    for (final f in fields)
      "'${f.keyLiteral}': ${existing[f.name] ?? dartLiteral(f.type.schemaJson())}",
  ];
  final required = [
    for (final f in fields)
      if (!f.type.nullable) "'${f.keyLiteral}'",
  ];
  final deps = <String>{};
  for (final f in fields) {
    f.type.collectDtoRefs(deps);
  }

  final buffer = StringBuffer("Schema('$className', {'type': 'object'");
  if (required.isNotEmpty) {
    buffer.write(", 'required': [${required.join(', ')}]");
  }
  buffer.write(", 'properties': {${properties.join(', ')}}");
  for (final extra in extras) {
    buffer.write(', $extra');
  }
  buffer.write('}');
  final depList = deps.toList()..sort();
  if (depList.isNotEmpty) {
    buffer.write(
      ', deps: [${depList.map((d) => '${_lowerFirst(d)}Schema').join(', ')}]',
    );
  }
  buffer.write(')');
  return buffer.toString();
}

// --- mapper generation ----------------------------------------------------

String _fromJsonSource(String className, List<CanonicalField> fields) {
  final buffer = StringBuffer(
    '  factory $className.fromJson(Map<String, Object?> json) => $className(\n',
  );
  for (final f in fields) {
    buffer.writeln('        ${f.name}: ${f.fromJsonExpr()},');
  }
  buffer.write('      );');
  return buffer.toString();
}

String _toJsonSource(List<CanonicalField> fields) {
  final buffer = StringBuffer('  Map<String, Object?> toJson() => {\n');
  for (final f in fields) {
    buffer.writeln(f.toJsonEntry());
  }
  buffer.write('      };');
  return buffer.toString();
}

String _lowerFirst(String s) =>
    s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';
