library;

import 'dart:typed_data';

import 'package:keta_native/keta_native.dart';

import '../jwt/algorithm.dart';
import '../jwt/jwk.dart';
import '../jwt/signature_verifier.dart';

/// The production [SignatureVerifier], backed by BoringSSL through
/// `package:keta_native`. It is the piece that turns keta_oidc's pure-Dart JWT
/// core into a real verifier: the JWT layer parses and applies policy, and this
/// class does the one cryptographic check, over an audited libcrypto rather than
/// a hand-rolled big-integer routine.
///
/// ## JOSE ↔ crypto adaptation is *this* class's job
///
/// This class owns the impedance mismatch between JOSE and the crypto backend:
///
/// * **ECDSA signatures.** JOSE carries an `ES*` signature as the raw fixed-width
///   `r ‖ s` concatenation (RFC 7518 §3.4); BoringSSL's ECDSA verify takes an
///   ASN.1 **DER** `SEQUENCE { r, s }`. The raw→DER conversion happens here, in
///   pure Dart, before the native call — so the seam contract (raw `r ‖ s`
///   crosses it) holds and the backend stays JOSE-agnostic.
/// * **Key conversion is cached by [Jwk] identity.** Importing raw JWK
///   components into a native `EVP_PKEY` is not free, and the JWKS cache hands
///   out the *same* [Jwk] instance across calls (see [Jwk]). This verifier
///   therefore caches the derived [RsaPublicKey] / [EcPublicKey] in an [Expando]
///   keyed on the [Jwk] instance — one import per key, then an identity lookup
///   per verify. The two families are cached in separately-typed [Expando]s, so
///   there is no per-call map work beyond the expando read.
///
/// ## Error posture (matches the seam contract)
///
/// * A signature that simply does not verify — including one whose length is not
///   a valid `r ‖ s` for the algorithm — returns **`false`**. A wrong-length
///   ECDSA signature cannot be a valid JOSE signature, so it fails closed
///   *without* a native call.
/// * A **backend defect throws.** A [Jwk] whose components are absent for the
///   requested algorithm family is an author defect (the validator normally
///   cross-checks this first) and throws [StateError]. A JWKS-supplied key that
///   is base64url-clean but cryptographically invalid — bad RSA components, an
///   EC point off the curve, a mis-sized coordinate — makes `keta_native` throw
///   [ArgumentError] at import, and that **propagates**. This is deliberate: a
///   broken IdP key is surfaced as a thrown error, *not* laundered into "the
///   signature is bad", so an operator sees a key problem rather than a stream
///   of 401s.
final class BoringSslVerifier implements SignatureVerifier {
  /// Creates a verifier with its own key-conversion caches. A single instance is
  /// meant to be shared (e.g. held by the app's `Env`); the caches then span the
  /// life of that instance, exactly matching the lifetime of the [Jwk] instances
  /// the JWKS cache reuses.
  BoringSslVerifier();

  final Expando<RsaPublicKey> _rsaKeys = Expando<RsaPublicKey>('keta_oidc.rsa');
  final Expando<EcPublicKey> _ecKeys = Expando<EcPublicKey>('keta_oidc.ec');

  @override
  bool verify({
    required Jwk key,
    required JwsAlgorithm algorithm,
    required Uint8List signingInput,
    required Uint8List signature,
  }) {
    switch (algorithm) {
      case JwsAlgorithm.rs256:
        return _rsaKey(key).verifyPkcs1Sha256(signingInput, signature);
      case JwsAlgorithm.rs384:
        return _rsaKey(key).verifyPkcs1Sha384(signingInput, signature);
      case JwsAlgorithm.rs512:
        return _rsaKey(key).verifyPkcs1Sha512(signingInput, signature);
      case JwsAlgorithm.es256:
        final der = joseEcdsaSignatureToDer(signature, 32);
        if (der == null) return false;
        return _ecKey(key).verifyEcdsaSha256(signingInput, der);
      case JwsAlgorithm.es384:
        final der = joseEcdsaSignatureToDer(signature, 48);
        if (der == null) return false;
        return _ecKey(key).verifyEcdsaSha384(signingInput, der);
    }
  }

  RsaPublicKey _rsaKey(Jwk key) {
    final cached = _rsaKeys[key];
    if (cached != null) return cached;
    final modulus = key.modulus;
    final exponent = key.exponent;
    if (modulus == null || exponent == null) {
      throw StateError(
        'an RSA algorithm needs an RSA JWK (n/e), but the key is '
        '${key.keyType.joseName}',
      );
    }
    // May throw ArgumentError for a cryptographically invalid key — propagated
    // as a backend defect, deliberately not swallowed into `false`.
    final built = RsaPublicKey.fromComponents(modulus, exponent);
    _rsaKeys[key] = built;
    return built;
  }

  EcPublicKey _ecKey(Jwk key) {
    final cached = _ecKeys[key];
    if (cached != null) return cached;
    final x = key.x;
    final y = key.y;
    if (x == null || y == null) {
      throw StateError(
        'an EC algorithm needs an EC JWK (x/y), but the key is '
        '${key.keyType.joseName}',
      );
    }
    // Build on the key's own curve. The validator has already cross-checked that
    // the key's curve matches the algorithm; if this is somehow reached with a
    // mismatch, the raw→DER length check or the crypto returns `false` rather
    // than mis-verifying.
    final built = switch (key.curve) {
      'P-256' => EcPublicKey.p256(x, y),
      'P-384' => EcPublicKey.p384(x, y),
      _ => throw StateError('unsupported EC curve ${key.curve}'),
    };
    _ecKeys[key] = built;
    return built;
  }
}

/// Converts a raw JOSE ECDSA signature — the fixed-width `r ‖ s` concatenation —
/// into the ASN.1 **DER** `SEQUENCE { r INTEGER, s INTEGER }` that BoringSSL's
/// ECDSA verify expects. [fieldSize] is the curve's field size in bytes (32 for
/// P-256 / `ES256`, 48 for P-384 / `ES384`).
///
/// Returns `null` when [raw] is not exactly `2 * fieldSize` bytes: such input
/// cannot be a valid JOSE `ES*` signature, and the caller turns a `null` into a
/// `false` verification without ever touching the crypto backend.
///
/// The INTEGER encoding is minimal-DER: leading zero bytes are stripped, and a
/// leading `0x00` is prepended when the high bit of the first magnitude byte is
/// set (so the value is not read as negative). An all-zero `r` or `s` still
/// encodes (to INTEGER `0`) and is handed to BoringSSL — encoding keeps no
/// policy; the crypto rejects a zero scalar.
Uint8List? joseEcdsaSignatureToDer(Uint8List raw, int fieldSize) {
  if (raw.length != 2 * fieldSize) {
    // Not a valid JOSE r‖s for this algorithm — fail closed, no native call.
    return null;
  }
  final r = _derInteger(Uint8List.sublistView(raw, 0, fieldSize));
  final s = _derInteger(Uint8List.sublistView(raw, fieldSize));

  final contentLength = r.length + s.length;
  final out = BytesBuilder(copy: false);
  out.addByte(0x30); // SEQUENCE
  _addDerLength(out, contentLength);
  out.add(r);
  out.add(s);
  return out.toBytes();
}

/// Encodes a big-endian unsigned [magnitude] as a full DER INTEGER TLV
/// (`0x02`, length, content).
Uint8List _derInteger(Uint8List magnitude) {
  // Strip leading zero bytes, but keep one byte if the value is all zero so a
  // zero scalar encodes as INTEGER 0 (0x02 0x01 0x00).
  var start = 0;
  while (start < magnitude.length - 1 && magnitude[start] == 0) {
    start++;
  }
  var body = Uint8List.sublistView(magnitude, start);

  // If the top bit is set, DER would read the value as negative — prepend a
  // 0x00 sign byte to keep it a positive integer.
  if ((body[0] & 0x80) != 0) {
    final padded = Uint8List(body.length + 1);
    padded.setRange(1, padded.length, body);
    body = padded;
  }

  final out = BytesBuilder(copy: false);
  out.addByte(0x02); // INTEGER
  _addDerLength(out, body.length);
  out.add(body);
  return out.toBytes();
}

/// Appends a DER length octet sequence for [length].
///
/// For P-256/P-384 ECDSA every length here is small: each INTEGER body is at
/// most `fieldSize + 1` bytes (49 for P-384) and the SEQUENCE content is at most
/// `2 * (2 + fieldSize + 1)` bytes (102 for P-384) — all well under 128, so in
/// practice only the short form is ever emitted. The `0x81` (one-byte long form)
/// branch is kept for correctness and can only be reached for lengths 128..255;
/// a length can never reach 256 for these curves.
void _addDerLength(BytesBuilder out, int length) {
  assert(
    length < 256,
    'DER length $length unexpectedly >= 256 for an ECDSA signature',
  );
  if (length < 128) {
    out.addByte(length); // short form
  } else {
    out.addByte(0x81); // one-byte long form
    out.addByte(length);
  }
}
