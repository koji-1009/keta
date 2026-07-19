/// Test-support key generation. Not part of the verify-only production surface
/// — exposed via `package:keta_native/testing.dart` so consumers (and this
/// package's own suite) can mint keys, sign, and build JWKS fixtures.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'ec.dart';
import 'error.dart';
import 'ffi/libcrypto.dart';
import 'pkey.dart';
import 'rsa.dart';

/// A freshly generated RSA key pair, for tests and fixtures.
///
/// Holds the private key natively (used by the `sign*` methods) and exposes the
/// public components as big-endian, unsigned bytes so a JWKS `n`/`e` can be
/// built directly. The native key is freed on garbage collection.
final class RsaKeyPair implements Finalizable {
  RsaKeyPair._(this._pkey, this.modulus, this.exponent);

  /// Generates a new RSA key of [bits] modulus size (default 2048) with the
  /// standard public exponent F4 (65537).
  factory RsaKeyPair.generate([int bits = 2048]) {
    if (bits < 512) {
      throw ArgumentError.value(bits, 'bits', 'must be at least 512');
    }
    final e = BN_new();
    if (e == nullptr) {
      throw StateError('BN_new failed: ${consumeBoringSslError()}');
    }
    Pointer<RSA> rsa = nullptr;
    try {
      if (BN_set_word(e, 65537) != 1) {
        throw StateError('BN_set_word failed: ${consumeBoringSslError()}');
      }
      rsa = RSA_new();
      if (rsa == nullptr) {
        throw StateError('RSA_new failed: ${consumeBoringSslError()}');
      }
      if (RSA_generate_key_ex(rsa, bits, e, nullptr) != 1) {
        throw StateError(
          'RSA_generate_key_ex failed: ${consumeBoringSslError()}',
        );
      }
      final modulus = bnToBytes(RSA_get0_n(rsa));
      final exponent = bnToBytes(RSA_get0_e(rsa));
      final pkey = EVP_PKEY_new();
      if (pkey == nullptr) {
        throw StateError('EVP_PKEY_new failed: ${consumeBoringSslError()}');
      }
      if (EVP_PKEY_assign_RSA(pkey, rsa) != 1) {
        EVP_PKEY_free(pkey);
        throw StateError(
          'EVP_PKEY_assign_RSA failed: ${consumeBoringSslError()}',
        );
      }
      rsa = nullptr; // Ownership moved into pkey.
      final pair = RsaKeyPair._(pkey, modulus, exponent);
      pkeyFinalizer.attach(pair, pkey.cast(), detach: pair);
      return pair;
    } finally {
      BN_free(e);
      if (rsa != nullptr) {
        RSA_free(rsa);
      }
    }
  }

  final Pointer<EVP_PKEY> _pkey;

  /// The public modulus (JWK `n`), big-endian unsigned.
  final Uint8List modulus;

  /// The public exponent (JWK `e`), big-endian unsigned (65537 → `AQAB`).
  final Uint8List exponent;

  /// Signs [message] as `RS256` (RSASSA-PKCS1-v1_5 over SHA-256).
  Uint8List signPkcs1Sha256(Uint8List message) =>
      signDigest(_pkey, EVP_sha256(), message);

  /// Signs [message] as `RS384`.
  Uint8List signPkcs1Sha384(Uint8List message) =>
      signDigest(_pkey, EVP_sha384(), message);

  /// Signs [message] as `RS512`.
  Uint8List signPkcs1Sha512(Uint8List message) =>
      signDigest(_pkey, EVP_sha512(), message);

  /// The matching verify-only [RsaPublicKey], rebuilt from the public
  /// components — the object a resource server would hold.
  RsaPublicKey publicKey() => RsaPublicKey.fromComponents(modulus, exponent);
}

/// A freshly generated NIST P-256 or P-384 EC key pair, for tests and
/// fixtures.
///
/// Exposes the public affine coordinates as fixed-width big-endian values (JWK
/// `x`/`y`) — 32 bytes on P-256, 48 on P-384. The native key is freed on
/// garbage collection.
final class EcKeyPair implements Finalizable {
  EcKeyPair._(this._pkey, this._fieldSize, this.x, this.y);

  /// Generates a new P-256 key pair (for `ES256`).
  factory EcKeyPair.generateP256() => _generate(NID_X9_62_prime256v1, 32);

  /// Generates a new P-384 key pair (for `ES384`).
  factory EcKeyPair.generateP384() => _generate(NID_secp384r1, 48);

  static EcKeyPair _generate(int nid, int fieldSize) {
    Pointer<EC_KEY> ec = EC_KEY_new_by_curve_name(nid);
    if (ec == nullptr) {
      throw StateError(
        'EC_KEY_new_by_curve_name failed: ${consumeBoringSslError()}',
      );
    }
    final xBn = BN_new();
    if (xBn == nullptr) {
      EC_KEY_free(ec);
      throw StateError('BN_new failed: ${consumeBoringSslError()}');
    }
    final yBn = BN_new();
    if (yBn == nullptr) {
      BN_free(xBn);
      EC_KEY_free(ec);
      throw StateError('BN_new failed: ${consumeBoringSslError()}');
    }
    try {
      if (EC_KEY_generate_key(ec) != 1) {
        throw StateError(
          'EC_KEY_generate_key failed: ${consumeBoringSslError()}',
        );
      }
      final group = EC_KEY_get0_group(ec);
      final point = EC_KEY_get0_public_key(ec);
      if (EC_POINT_get_affine_coordinates_GFp(
            group,
            point,
            xBn,
            yBn,
            nullptr,
          ) !=
          1) {
        throw StateError(
          'EC_POINT_get_affine_coordinates_GFp failed: '
          '${consumeBoringSslError()}',
        );
      }
      final x = bnToBytes(xBn, padTo: fieldSize);
      final y = bnToBytes(yBn, padTo: fieldSize);
      final pkey = EVP_PKEY_new();
      if (pkey == nullptr) {
        throw StateError('EVP_PKEY_new failed: ${consumeBoringSslError()}');
      }
      if (EVP_PKEY_assign_EC_KEY(pkey, ec) != 1) {
        EVP_PKEY_free(pkey);
        throw StateError(
          'EVP_PKEY_assign_EC_KEY failed: ${consumeBoringSslError()}',
        );
      }
      ec = nullptr; // Ownership moved into pkey.
      final pair = EcKeyPair._(pkey, fieldSize, x, y);
      pkeyFinalizer.attach(pair, pkey.cast(), detach: pair);
      return pair;
    } finally {
      BN_free(xBn);
      BN_free(yBn);
      if (ec != nullptr) {
        EC_KEY_free(ec);
      }
    }
  }

  final Pointer<EVP_PKEY> _pkey;
  final int _fieldSize;

  /// The public key's affine x-coordinate (JWK `x`), big-endian.
  final Uint8List x;

  /// The public key's affine y-coordinate (JWK `y`), big-endian.
  final Uint8List y;

  /// Signs [message] with ECDSA over SHA-256, returning a DER-encoded
  /// signature. On a P-256 pair this is `ES256`.
  Uint8List signEcdsaSha256(Uint8List message) =>
      signDigest(_pkey, EVP_sha256(), message);

  /// Signs [message] with ECDSA over SHA-384, returning a DER-encoded
  /// signature. On a P-384 pair this is `ES384`.
  Uint8List signEcdsaSha384(Uint8List message) =>
      signDigest(_pkey, EVP_sha384(), message);

  /// The matching verify-only [EcPublicKey] on this pair's curve, rebuilt from
  /// `x`/`y`.
  EcPublicKey publicKey() =>
      _fieldSize == 32 ? EcPublicKey.p256(x, y) : EcPublicKey.p384(x, y);
}
