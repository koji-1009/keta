library;

import 'dart:convert';
import 'dart:typed_data';

import 'algorithm.dart';
import 'base64url.dart';
import 'rejection.dart';

/// A parsed JSON Web Key (RFC 7517) holding a **public** verification key, in
/// the two families keta_oidc verifies with: RSA (`kty: RSA`, components `n`/`e`)
/// and elliptic-curve (`kty: EC`, components `crv`/`x`/`y`).
///
/// ## Raw components, not backend keys
///
/// A [Jwk] carries the key material as the **raw big-endian byte strings** the
/// JWK JSON encodes ([modulus]/[exponent], or [x]/[y]) — it does not import them
/// into any cryptographic backend. The [SignatureVerifier] does that
/// conversion, which keeps this model free of any crypto dependency and lets the
/// backend be swapped.
///
/// ## Long-lived, and cacheable by identity
///
/// [Jwk] instances are **long-lived and reused across calls**: the JWKS cache (a
/// later wave) parses a key once and hands the *same* instance to the verifier
/// for every token that key signs. A backend that must convert the raw
/// components into a native key object (and would rather not repeat that work
/// per request) MAY cache the derived key **keyed on [Jwk] identity** — an
/// [Expando] over the [Jwk] instance is the intended mechanism. This class is
/// immutable and exposes no mutable slot precisely so that caching is the
/// backend's private concern, attached by identity, invalidated naturally when
/// the cache drops the key and the instance becomes unreachable.
final class Jwk {
  const Jwk._({
    required this.keyType,
    required this.kid,
    required this.algorithm,
    required this.use,
    required this.keyOps,
    required this.curve,
    required this.modulus,
    required this.exponent,
    required this.x,
    required this.y,
  });

  /// Parses a single JWK from its decoded-JSON [Map].
  ///
  /// Throws [JwtMalformed] when the object is not a usable public key of a
  /// supported family: an unknown or missing `kty`, a `kty` whose required
  /// components are absent or not strict base64url, or an EC `crv` outside the
  /// supported curves. A declared `alg` outside the [JwsAlgorithm] allowlist is
  /// **not** fatal here — it is retained as `null` so key parsing does not
  /// double as algorithm policy (the token's own `alg` is what policy gates);
  /// the well-known `alg` values still round-trip.
  factory Jwk.fromJson(Map<String, Object?> json) {
    final ktyRaw = json['kty'];
    if (ktyRaw is! String) {
      throw const JwtMalformed('JWK has no string "kty"');
    }
    final keyType = JwkKeyType.fromJose(ktyRaw);
    if (keyType == null) {
      throw JwtMalformed(
        'JWK "kty" "$ktyRaw" is not a supported key type (RSA or EC)',
      );
    }

    final kid = _optionalString(json, 'kid');
    final use = _optionalString(json, 'use');
    final algRaw = _optionalString(json, 'alg');
    // A declared "alg" outside the allowlist is retained as null rather than
    // rejected: this is the key model, not the policy gate. The token's own alg
    // is what the validator checks against the allowlist.
    final algorithm = algRaw == null ? null : JwsAlgorithm.fromJose(algRaw);

    final keyOpsRaw = json['key_ops'];
    List<String>? keyOps;
    if (keyOpsRaw != null) {
      if (keyOpsRaw is! List || keyOpsRaw.any((e) => e is! String)) {
        throw const JwtMalformed('JWK "key_ops" must be an array of strings');
      }
      keyOps = List<String>.unmodifiable(keyOpsRaw.cast<String>());
    }

    switch (keyType) {
      case JwkKeyType.rsa:
        return Jwk._(
          keyType: keyType,
          kid: kid,
          algorithm: algorithm,
          use: use,
          keyOps: keyOps,
          curve: null,
          modulus: _requireBase64Url(json, 'n', 'RSA'),
          exponent: _requireBase64Url(json, 'e', 'RSA'),
          x: null,
          y: null,
        );
      case JwkKeyType.ec:
        final crv = json['crv'];
        if (crv is! String) {
          throw const JwtMalformed('EC JWK has no string "crv"');
        }
        if (crv != 'P-256' && crv != 'P-384') {
          throw JwtMalformed(
            'EC JWK "crv" "$crv" is not a supported curve (P-256 or P-384)',
          );
        }
        return Jwk._(
          keyType: keyType,
          kid: kid,
          algorithm: algorithm,
          use: use,
          keyOps: keyOps,
          curve: crv,
          modulus: null,
          exponent: null,
          x: _requireBase64Url(json, 'x', 'EC'),
          y: _requireBase64Url(json, 'y', 'EC'),
        );
    }
  }

  /// Parses a single JWK from its JSON [text].
  factory Jwk.parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw JwtMalformed('JWK is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const JwtMalformed('JWK is not a JSON object');
    }
    return Jwk.fromJson(decoded);
  }

  /// The key family (`kty`): [JwkKeyType.rsa] or [JwkKeyType.ec].
  final JwkKeyType keyType;

  /// The key id (`kid`), or `null`. Used by the JWKS cache to match a token's
  /// header `kid` to this key.
  final String? kid;

  /// The algorithm this key declares (`alg`), or `null` when the JWK omits it or
  /// declares one outside the [JwsAlgorithm] allowlist. When non-null, the
  /// validator cross-checks it against the token's `alg` (a key that says
  /// `RS256` must not be used to verify an `ES256` token).
  final JwsAlgorithm? algorithm;

  /// The intended use (`use`), typically `"sig"`, or `null`.
  final String? use;

  /// The permitted key operations (`key_ops`), or `null`.
  final List<String>? keyOps;

  /// The EC curve (`crv`) — `"P-256"` or `"P-384"` — for an [JwkKeyType.ec] key,
  /// else `null`.
  final String? curve;

  /// RSA modulus (`n`) as raw big-endian bytes, for an [JwkKeyType.rsa] key,
  /// else `null`.
  final Uint8List? modulus;

  /// RSA public exponent (`e`) as raw big-endian bytes, for an [JwkKeyType.rsa]
  /// key, else `null`.
  final Uint8List? exponent;

  /// EC public-point x-coordinate (`x`) as raw big-endian bytes, for an
  /// [JwkKeyType.ec] key, else `null`.
  final Uint8List? x;

  /// EC public-point y-coordinate (`y`) as raw big-endian bytes, for an
  /// [JwkKeyType.ec] key, else `null`.
  final Uint8List? y;

  static String? _optionalString(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is! String) {
      throw JwtMalformed('JWK "$key" must be a string');
    }
    return v;
  }

  static Uint8List _requireBase64Url(
    Map<String, Object?> json,
    String key,
    String family,
  ) {
    final v = json[key];
    if (v is! String) {
      throw JwtMalformed('$family JWK has no string "$key" component');
    }
    return decodeBase64Url(v, '$family "$key"');
  }
}
