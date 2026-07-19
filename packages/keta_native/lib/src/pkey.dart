/// Shared native machinery for the public and test-support key types: building
/// `EVP_PKEY` handles from key material, one-shot sign/verify, BIGNUM <-> bytes
/// conversion, and the finalizer that frees a long-lived `EVP_PKEY`.
///
/// Memory discipline here is uniform: every temporary native object (BIGNUM,
/// RSA, EC_KEY, EVP_MD_CTX, scratch buffers) is freed on all paths via
/// try/finally; only the returned `EVP_PKEY` outlives the call, guarded by
/// [pkeyFinalizer]. The BoringSSL error queue is drained wherever an error is
/// consumed so state never bleeds between calls.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'error.dart';
import 'ffi/libcrypto.dart';

/// Frees the `EVP_PKEY` a wrapper object no longer references. Attached to the
/// Dart wrapper so the native key is released when the wrapper is collected,
/// without requiring an explicit `close()`.
final NativeFinalizer pkeyFinalizer = NativeFinalizer(
  Native.addressOf<NativeFunction<Void Function(Pointer<EVP_PKEY>)>>(
    EVP_PKEY_free,
  ).cast(),
);

/// Copies [bytes] into a fresh BIGNUM (big-endian, unsigned). The caller owns
/// the result and must [BN_free] it. A zero-length input yields the BIGNUM 0.
Pointer<BIGNUM> bytesToBn(Uint8List bytes) {
  final len = bytes.isEmpty ? 1 : bytes.length;
  final ptr = malloc<Uint8>(len);
  try {
    if (bytes.isNotEmpty) {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
    }
    final bn = BN_bin2bn(ptr, bytes.length, nullptr);
    if (bn == nullptr) {
      throw StateError('BN_bin2bn failed: ${consumeBoringSslError()}');
    }
    return bn;
  } finally {
    malloc.free(ptr);
  }
}

/// Serializes [bn] to big-endian, unsigned bytes. When [padTo] is given the
/// result is left-zero-padded to exactly that length — the fixed-width form JWK
/// coordinates (`n`, `e`, `x`, `y`) require.
Uint8List bnToBytes(Pointer<BIGNUM> bn, {int? padTo}) {
  final size = BN_num_bytes(bn);
  final buf = malloc<Uint8>(size == 0 ? 1 : size);
  try {
    final written = BN_bn2bin(bn, buf);
    final raw = Uint8List.fromList(buf.asTypedList(written));
    if (padTo != null && raw.length < padTo) {
      final padded = Uint8List(padTo);
      padded.setRange(padTo - raw.length, padTo, raw);
      return padded;
    }
    return raw;
  } finally {
    malloc.free(buf);
  }
}

/// Builds a public `EVP_PKEY` wrapping an RSA key with the given big-endian
/// modulus and exponent. Throws [ArgumentError] (carrying the BoringSSL error
/// string) when the components do not form a valid key.
Pointer<EVP_PKEY> buildRsaPublicKey(Uint8List modulus, Uint8List exponent) {
  final n = bytesToBn(modulus);
  final e = bytesToBn(exponent);
  Pointer<RSA> rsa = nullptr;
  try {
    rsa = RSA_new_public_key(n, e);
    if (rsa == nullptr) {
      throw ArgumentError('invalid RSA public key: ${consumeBoringSslError()}');
    }
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
    return pkey;
  } finally {
    BN_free(n);
    BN_free(e);
    if (rsa != nullptr) {
      RSA_free(rsa);
    }
  }
}

/// Builds a public `EVP_PKEY` wrapping an EC key on curve [nid] with the given
/// big-endian affine coordinates. Throws [ArgumentError] when the point is not
/// a valid public key on the curve.
Pointer<EVP_PKEY> buildEcPublicKey(int nid, Uint8List x, Uint8List y) {
  final xBn = bytesToBn(x);
  final yBn = bytesToBn(y);
  Pointer<EC_KEY> key = nullptr;
  try {
    key = EC_KEY_new_by_curve_name(nid);
    if (key == nullptr) {
      throw StateError(
        'EC_KEY_new_by_curve_name failed: ${consumeBoringSslError()}',
      );
    }
    if (EC_KEY_set_public_key_affine_coordinates(key, xBn, yBn) != 1) {
      throw ArgumentError(
        'invalid EC public key point: ${consumeBoringSslError()}',
      );
    }
    final pkey = EVP_PKEY_new();
    if (pkey == nullptr) {
      throw StateError('EVP_PKEY_new failed: ${consumeBoringSslError()}');
    }
    if (EVP_PKEY_assign_EC_KEY(pkey, key) != 1) {
      EVP_PKEY_free(pkey);
      throw StateError(
        'EVP_PKEY_assign_EC_KEY failed: ${consumeBoringSslError()}',
      );
    }
    key = nullptr; // Ownership moved into pkey.
    return pkey;
  } finally {
    BN_free(xBn);
    BN_free(yBn);
    if (key != nullptr) {
      EC_KEY_free(key);
    }
  }
}

/// One-shot signature verification of [message] under [pkey] with digest [md].
/// The padding/algorithm follows the key type: PKCS#1 v1.5 for RSA, ECDSA
/// (DER-encoded [signature]) for EC.
///
/// Returns `true` only on a cryptographically valid signature. A mismatch —
/// or any non-success verify result — returns `false` after clearing the error
/// queue; verification never throws for bad input, per the error posture. A
/// failure to even set up the context is an impossible state ([StateError]),
/// since [pkey] was validated at construction.
bool verifyDigest(
  Pointer<EVP_PKEY> pkey,
  Pointer<EVP_MD> md,
  Uint8List message,
  Uint8List signature,
) {
  final ctx = EVP_MD_CTX_new();
  if (ctx == nullptr) {
    throw StateError('EVP_MD_CTX_new failed: ${consumeBoringSslError()}');
  }
  final msgPtr = malloc<Uint8>(message.isEmpty ? 1 : message.length);
  final sigPtr = malloc<Uint8>(signature.isEmpty ? 1 : signature.length);
  try {
    if (message.isNotEmpty) {
      msgPtr.asTypedList(message.length).setAll(0, message);
    }
    if (signature.isNotEmpty) {
      sigPtr.asTypedList(signature.length).setAll(0, signature);
    }
    if (EVP_DigestVerifyInit(ctx, nullptr, md, nullptr, pkey) != 1) {
      throw StateError(
        'EVP_DigestVerifyInit failed: ${consumeBoringSslError()}',
      );
    }
    final rc = EVP_DigestVerify(
      ctx,
      sigPtr,
      signature.length,
      msgPtr,
      message.length,
    );
    if (rc == 1) {
      return true;
    }
    // rc == 0 is the expected mismatch; a negative rc is a malformed signature
    // (e.g. non-DER ECDSA bytes). Both are verification failures here. Clear
    // the queue so the rejection does not leak into the next call.
    ERR_clear_error();
    return false;
  } finally {
    EVP_MD_CTX_free(ctx);
    malloc
      ..free(msgPtr)
      ..free(sigPtr);
  }
}

/// One-shot signing of [message] under [pkey] with digest [md]. RSA produces a
/// PKCS#1 v1.5 signature; EC produces a DER-encoded ECDSA signature. Test
/// support only — mirrors [verifyDigest].
Uint8List signDigest(
  Pointer<EVP_PKEY> pkey,
  Pointer<EVP_MD> md,
  Uint8List message,
) {
  final ctx = EVP_MD_CTX_new();
  if (ctx == nullptr) {
    throw StateError('EVP_MD_CTX_new failed: ${consumeBoringSslError()}');
  }
  final msgPtr = malloc<Uint8>(message.isEmpty ? 1 : message.length);
  final sigLen = malloc<Size>();
  try {
    if (message.isNotEmpty) {
      msgPtr.asTypedList(message.length).setAll(0, message);
    }
    if (EVP_DigestSignInit(ctx, nullptr, md, nullptr, pkey) != 1) {
      throw StateError('EVP_DigestSignInit failed: ${consumeBoringSslError()}');
    }
    // First call: probe the maximum signature length into sigLen.
    if (EVP_DigestSign(ctx, nullptr, sigLen, msgPtr, message.length) != 1) {
      throw StateError(
        'EVP_DigestSign (size probe) failed: ${consumeBoringSslError()}',
      );
    }
    final sig = malloc<Uint8>(sigLen.value);
    try {
      // Second call: produce the signature; sigLen is narrowed to its length.
      if (EVP_DigestSign(ctx, sig, sigLen, msgPtr, message.length) != 1) {
        throw StateError('EVP_DigestSign failed: ${consumeBoringSslError()}');
      }
      return Uint8List.fromList(sig.asTypedList(sigLen.value));
    } finally {
      malloc.free(sig);
    }
  } finally {
    EVP_MD_CTX_free(ctx);
    malloc
      ..free(msgPtr)
      ..free(sigLen);
  }
}
