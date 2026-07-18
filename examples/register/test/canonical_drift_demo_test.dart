/// The canonical drift-repair loop, round-tripped against THIS example's own
/// DTO — not a synthetic fixture built to flatter the tool. A copier who
/// deletes this loses the only test that proves keta_lints' check/fix loop
/// actually converges on real source, not just a crafted sample.
///
/// Take the real lib/user_dto.dart source, simulate the single most ordinary
/// edit there is — adding a field — with string surgery on a copy (never on
/// the file on disk: this test must leave the tree untouched), and assert:
///
///  1. `canonicalDiagnostics` reports the drift the new field creates, naming
///     it (the "check" half of the README's "When you add a field" loop).
///  2. `applyCanonicalFix` reconciles fromJson, toJson, and the Schema
///     constant, and the diagnostics go clean afterward (the "fix" half).
///
/// If this ever fails because user_dto.dart's shape moved out from under the
/// string anchors below, that is real: fix the anchors to match, not around
/// them, because the point is this example's own DTO round-tripping.
library;

import 'dart:io';

import 'package:keta_lints/keta_lints.dart';
import 'package:test/test.dart';

void main() {
  test('adding a field is caught, then reconciled, by canonical fix', () {
    final original = File('lib/user_dto.dart').readAsStringSync();

    const ctorAnchor = 'required this.tags,\n  });';
    const fieldAnchor = 'final List<String> tags;';
    expect(
      original.contains(ctorAnchor) && original.contains(fieldAnchor),
      isTrue,
      reason:
          'lib/user_dto.dart no longer matches the shape this surgery '
          'assumes; update the anchors above to match its current source',
    );

    // The surgery: a new optional field, added the way anyone actually adds
    // one — a constructor parameter and a matching final field — with
    // fromJson, toJson, and the Schema constant deliberately left untouched.
    // That gap between the field set and the three things that must mirror it
    // IS the drift this test exists to demonstrate.
    final drifted = original
        .replaceFirst(
          ctorAnchor,
          'required this.tags,\n    this.nickname,\n  });',
        )
        .replaceFirst(fieldAnchor, '$fieldAnchor\n  final String? nickname;');
    expect(
      drifted,
      isNot(original),
      reason: 'the surgery above must actually change the source',
    );

    // Step 1 of the loop: `dart run keta_lints:check canonical lib/` fails,
    // naming the drift.
    final beforeFix = canonicalDiagnostics(drifted, file: 'lib/user_dto.dart');
    expect(beforeFix, isNotEmpty);
    expect(
      beforeFix.map((d) => d.rule),
      containsAll(['keta_canonical_drift', 'keta_schema_drift']),
    );
    expect(
      beforeFix.every((d) => d.message.contains('nickname')),
      isTrue,
      reason: 'the drift diagnostics should name the field that drifted',
    );

    // Step 2: `dart run keta_lints:fix canonical lib/` materializes the
    // repair.
    final fixed = applyCanonicalFix(drifted);
    expect(
      fixed,
      allOf(
        contains("nickname: json['nickname'] as String?"),
        contains("if (nickname != null) 'nickname': nickname"),
        contains("'nickname'"),
      ),
      reason:
          'the fix must materialize nickname into fromJson, toJson, and the '
          'Schema — not merely silence the diagnostic',
    );

    // Step 3: check is green again — the loop converges.
    final afterFix = canonicalDiagnostics(fixed, file: 'lib/user_dto.dart');
    expect(afterFix, isEmpty);
  });
}
