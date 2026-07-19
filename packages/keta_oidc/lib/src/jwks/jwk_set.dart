library;

import 'dart:convert';
import 'dart:typed_data';

import '../jwt/jwk.dart';
import '../jwt/jws.dart';
import '../jwt/rejection.dart';

/// A JWKS (JSON Web Key Set, RFC 7517 §5) that has been parsed into the keys
/// keta_oidc can actually verify with, plus a record of the entries it had to
/// [skipped] over.
///
/// ## Skipping, not rejecting
///
/// A published JWKS routinely mixes in keys this package cannot use: a symmetric
/// `oct` key, a key marked `use: "enc"`, a curve outside P-256/P-384, an entry
/// with a malformed component. [fromJson] **skips** each such entry (recording
/// it in [skipped]) instead of failing the whole document — a modern or hostile
/// IdP publishing one unusable key next to the working ones must not brick
/// verification. Only a document whose *shape* is wrong — top level not a JSON
/// object, or no `keys` array — is [JwksMalformed].
///
/// ## Duplicate `kid`: last-wins
///
/// If two usable keys share a `kid`, the one appearing **later** in the `keys`
/// array wins (it replaces the earlier at that position). A duplicate `kid` is
/// irregular; last-wins is the deterministic rule this package commits to, so
/// `kid` lookup is unambiguous. Keys with no `kid` are all retained (they are
/// only ever selected when the set holds exactly one usable key).
final class JwkSet {
  const JwkSet._(this.keys, this.skipped);

  /// Parses a JWKS from its JSON [text]. Throws [JwksMalformed] when [text] is
  /// not valid JSON or its top level is not a JSON object.
  factory JwkSet.parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw JwksMalformed('JWKS is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const JwksMalformed('JWKS is not a JSON object');
    }
    return JwkSet.fromJson(decoded);
  }

  /// Parses a JWKS from its decoded-JSON [json].
  ///
  /// Throws [JwksMalformed] when there is no `keys` array. Individual unusable
  /// entries are skipped into [skipped], never thrown.
  factory JwkSet.fromJson(Map<String, Object?> json) {
    final keysRaw = json['keys'];
    if (keysRaw is! List) {
      throw const JwksMalformed('JWKS has no "keys" array');
    }

    final keys = <Jwk>[];
    final kidIndex = <String, int>{};
    final skipped = <SkippedJwk>[];

    for (final entry in keysRaw) {
      if (entry is! Map<String, Object?>) {
        skipped.add(const SkippedJwk('entry is not a JSON object', null));
        continue;
      }
      final entryKid = entry['kid'] is String ? entry['kid'] as String : null;

      final Jwk jwk;
      try {
        jwk = Jwk.fromJson(entry);
      } on JwtMalformed catch (e) {
        // Unusable family/shape (oct, an unsupported curve, a missing or
        // non-base64url component): skip this one key, keep the rest.
        skipped.add(SkippedJwk(e.message, entryKid));
        continue;
      }

      // A key explicitly published for encryption is not a verification key.
      if (jwk.use == 'enc') {
        skipped.add(
          SkippedJwk('key "use" is "enc", not a signature key', jwk.kid),
        );
        continue;
      }
      // If a key enumerates its operations, it must permit verification. A key
      // scoped to (say) "encrypt" or "sign" only is not one we may verify with —
      // the same posture as skipping a `use: "enc"` key, applied to the finer
      // `key_ops` declaration.
      final keyOps = jwk.keyOps;
      if (keyOps != null && !keyOps.contains('verify')) {
        skipped.add(
          SkippedJwk(
            'key "key_ops" $keyOps does not include "verify"',
            jwk.kid,
          ),
        );
        continue;
      }

      final kid = jwk.kid;
      if (kid != null && kidIndex.containsKey(kid)) {
        keys[kidIndex[kid]!] = jwk; // last-wins, in place
      } else {
        if (kid != null) kidIndex[kid] = keys.length;
        keys.add(jwk);
      }
    }

    return JwkSet._(List<Jwk>.unmodifiable(keys), List.unmodifiable(skipped));
  }

  /// The usable verification keys, in document order (with last-wins applied to
  /// duplicate `kid`s).
  final List<Jwk> keys;

  /// The entries that were skipped as unusable, each with the reason and the
  /// `kid` it carried (if any). Surfaced rather than logged so this package
  /// keeps no logging dependency; a caller may inspect or report it.
  final List<SkippedJwk> skipped;

  /// The number of skipped entries — a convenience over `skipped.length`.
  int get skippedCount => skipped.length;

  /// Selects the key that verifies a token with [header], or `null` when none
  /// applies:
  ///
  /// * with a `kid`: the key whose `kid` matches **exactly**, or `null`;
  /// * with no `kid`: the sole key when the set holds exactly one, otherwise
  ///   `null` (zero keys, or more than one — ambiguous).
  ///
  /// A `null` result is the signal to refresh or reject; this method never
  /// throws.
  Jwk? lookup(JoseHeader header) {
    final kid = header.kid;
    if (kid != null) {
      for (final key in keys) {
        if (key.kid == kid) return key;
      }
      return null;
    }
    return keys.length == 1 ? keys.single : null;
  }

  /// Returns a set equal to this freshly-parsed one, but **reusing the [Jwk]
  /// instances from [previous]** for every key whose `kid` and key material are
  /// unchanged.
  ///
  /// This preserves the seam's identity contract across a refresh: a key that
  /// survives a rotation keeps the *same* [Jwk] instance, so a [SignatureVerifier]
  /// that cached a derived native key against that instance (see [Jwk]) does not
  /// have to re-import it every TTL refresh. A key that is new, or whose material
  /// changed under the same `kid`, gets its fresh instance. Keys without a `kid`
  /// are never reconciled (there is no stable handle to match them by) and get
  /// fresh instances.
  JwkSet reconcileWith(JwkSet? previous) {
    if (previous == null) return this;
    final oldByKid = <String, Jwk>{
      for (final k in previous.keys)
        if (k.kid != null) k.kid!: k,
    };
    final reconciled = <Jwk>[
      for (final fresh in keys)
        () {
          final kid = fresh.kid;
          final old = kid == null ? null : oldByKid[kid];
          return old != null && _unchanged(old, fresh) ? old : fresh;
        }(),
    ];
    return JwkSet._(List<Jwk>.unmodifiable(reconciled), skipped);
  }

  /// Whether two keys are unchanged in every respect that matters to
  /// verification — not just the raw material, but the declared metadata the
  /// validator consults. A refresh that keeps a key's `kid` and bits but flips
  /// its declared `alg` (RS256 → RS512), `use`, or `key_ops` must **not** reuse
  /// the old instance: the validator's kid↔alg cross-check reads
  /// [Jwk.algorithm], so a stale declaration would keep being enforced. Identity
  /// preservation means "nothing about this key changed", not "the bits are the
  /// same".
  static bool _unchanged(Jwk a, Jwk b) =>
      a.keyType == b.keyType &&
      a.curve == b.curve &&
      a.algorithm == b.algorithm &&
      a.use == b.use &&
      _listEqual(a.keyOps, b.keyOps) &&
      _bytesEqual(a.modulus, b.modulus) &&
      _bytesEqual(a.exponent, b.exponent) &&
      _bytesEqual(a.x, b.x) &&
      _bytesEqual(a.y, b.y);

  static bool _listEqual(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One JWKS entry that [JwkSet] could not use, with the [reason] and the `kid`
/// it declared (if any).
final class SkippedJwk {
  const SkippedJwk(this.reason, this.kid);

  /// Why the entry was skipped (human-readable).
  final String reason;

  /// The `kid` the skipped entry carried, or `null` if it declared none (or the
  /// entry was too malformed to have a string `kid`).
  final String? kid;

  @override
  String toString() => 'SkippedJwk(${kid ?? '<no kid>'}: $reason)';
}

/// The JWKS *document* is structurally wrong — not valid JSON, top level not a
/// JSON object, or no `keys` array. Distinct from [JwtMalformed] (a bad token)
/// and from a document that merely contains some unusable keys (those are
/// skipped, not thrown). Not a [JwtRejection]: it describes the key source, not
/// a token.
final class JwksMalformed implements Exception {
  const JwksMalformed(this.message);

  /// A human-readable explanation.
  final String message;

  @override
  String toString() => 'JwksMalformed: $message';
}
