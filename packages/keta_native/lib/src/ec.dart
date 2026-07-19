import 'dart:ffi';
import 'dart:typed_data';

import 'ffi/libcrypto.dart';
import 'pkey.dart';

/// An elliptic-curve public key on NIST P-256 or P-384, for verifying ECDSA
/// signatures (JOSE `ES256` / `ES384`).
///
/// The signature passed to the verify methods is **DER-encoded** ECDSA
/// (`SEQUENCE { r INTEGER, s INTEGER }`). JOSE carries the signature as the raw
/// fixed-width `r || s` concatenation instead; converting that raw form to DER
/// is the caller's responsibility (e.g. keta_oidc does it for JWS).
///
/// The underlying native key is freed automatically on garbage collection.
final class EcPublicKey implements Finalizable {
  EcPublicKey._(this._pkey);

  /// A P-256 public key from big-endian affine coordinates ([x], [y], JWK
  /// `x`/`y`). Each coordinate must be exactly 32 bytes (the P-256 field size).
  factory EcPublicKey.p256(Uint8List x, Uint8List y) =>
      _fromAffine(NID_X9_62_prime256v1, 32, x, y);

  /// A P-384 public key from big-endian affine coordinates ([x], [y]). Each
  /// coordinate must be exactly 48 bytes (the P-384 field size).
  factory EcPublicKey.p384(Uint8List x, Uint8List y) =>
      _fromAffine(NID_secp384r1, 48, x, y);

  final Pointer<EVP_PKEY> _pkey;

  static EcPublicKey _fromAffine(
    int nid,
    int fieldSize,
    Uint8List x,
    Uint8List y,
  ) {
    if (x.length != fieldSize) {
      throw ArgumentError.value(
        x,
        'x',
        'must be exactly $fieldSize bytes for this curve',
      );
    }
    if (y.length != fieldSize) {
      throw ArgumentError.value(
        y,
        'y',
        'must be exactly $fieldSize bytes for this curve',
      );
    }
    final pkey = buildEcPublicKey(nid, x, y);
    final key = EcPublicKey._(pkey);
    pkeyFinalizer.attach(key, pkey.cast(), detach: key);
    return key;
  }

  /// Verifies an `ES256` signature: ECDSA over SHA-256 of [message], with
  /// [derSignature] DER-encoded. Returns `true` iff valid; never throws on a
  /// mismatch or a malformed signature.
  bool verifyEcdsaSha256(Uint8List message, Uint8List derSignature) =>
      verifyDigest(_pkey, EVP_sha256(), message, derSignature);

  /// Verifies an `ES384` signature: ECDSA over SHA-384 of [message], with
  /// [derSignature] DER-encoded.
  bool verifyEcdsaSha384(Uint8List message, Uint8List derSignature) =>
      verifyDigest(_pkey, EVP_sha384(), message, derSignature);
}
