import 'dart:ffi';
import 'dart:typed_data';

import 'ffi/libcrypto.dart';
import 'pkey.dart';

/// An RSA public key, for verifying RSASSA-PKCS1-v1_5 signatures (JOSE
/// `RS256`/`RS384`/`RS512`).
///
/// Construct one from JWK-shaped components with [RsaPublicKey.fromComponents].
/// The underlying native key is freed automatically when this object is
/// garbage-collected; there is no `close()` to call.
final class RsaPublicKey implements Finalizable {
  RsaPublicKey._(this._pkey);

  /// Builds a public key from big-endian, unsigned modulus ([modulus], JWK `n`)
  /// and exponent ([exponent], JWK `e`) bytes.
  ///
  /// Throws [ArgumentError] — carrying the BoringSSL error string — when the
  /// components do not form a valid RSA public key. As a fast, explicit guard,
  /// an empty modulus or an all-zero exponent is rejected before BoringSSL is
  /// consulted.
  factory RsaPublicKey.fromComponents(Uint8List modulus, Uint8List exponent) {
    if (modulus.isEmpty) {
      throw ArgumentError.value(modulus, 'modulus', 'must be non-empty');
    }
    if (exponent.isEmpty || exponent.every((byte) => byte == 0)) {
      throw ArgumentError.value(exponent, 'exponent', 'must be non-zero');
    }
    final pkey = buildRsaPublicKey(modulus, exponent);
    final key = RsaPublicKey._(pkey);
    pkeyFinalizer.attach(key, pkey.cast(), detach: key);
    return key;
  }

  final Pointer<EVP_PKEY> _pkey;

  /// Verifies an `RS256` signature: RSASSA-PKCS1-v1_5 over SHA-256 of
  /// [message]. Returns `true` iff [signature] is valid; never throws on a
  /// mismatch.
  bool verifyPkcs1Sha256(Uint8List message, Uint8List signature) =>
      verifyDigest(_pkey, EVP_sha256(), message, signature);

  /// Verifies an `RS384` signature (RSASSA-PKCS1-v1_5 over SHA-384).
  bool verifyPkcs1Sha384(Uint8List message, Uint8List signature) =>
      verifyDigest(_pkey, EVP_sha384(), message, signature);

  /// Verifies an `RS512` signature (RSASSA-PKCS1-v1_5 over SHA-512).
  bool verifyPkcs1Sha512(Uint8List message, Uint8List signature) =>
      verifyDigest(_pkey, EVP_sha512(), message, signature);
}
