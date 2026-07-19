import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'error.dart';
import 'ffi/libcrypto.dart';

Uint8List _digest(Uint8List data, Pointer<EVP_MD> md, int size) {
  final dataPtr = malloc<Uint8>(data.isEmpty ? 1 : data.length);
  final out = malloc<Uint8>(size);
  final outLen = malloc<Uint32>();
  try {
    if (data.isNotEmpty) {
      dataPtr.asTypedList(data.length).setAll(0, data);
    }
    if (EVP_Digest(dataPtr.cast(), data.length, out, outLen, md, nullptr) !=
        1) {
      throw StateError('EVP_Digest failed: ${consumeBoringSslError()}');
    }
    return Uint8List.fromList(out.asTypedList(size));
  } finally {
    malloc
      ..free(dataPtr)
      ..free(out)
      ..free(outLen);
  }
}

/// The SHA-256 digest of [data] (32 bytes).
Uint8List sha256(Uint8List data) => _digest(data, EVP_sha256(), 32);

/// The SHA-384 digest of [data] (48 bytes).
Uint8List sha384(Uint8List data) => _digest(data, EVP_sha384(), 48);

/// The SHA-512 digest of [data] (64 bytes).
Uint8List sha512(Uint8List data) => _digest(data, EVP_sha512(), 64);

Uint8List _hmac(Uint8List key, Uint8List data, Pointer<EVP_MD> md, int size) {
  // Allocated length, tracked separately from `key.length`: an empty key
  // still gets a 1-byte allocation (malloc(0) is unspecified), and the
  // zeroization pass below must cover exactly what was allocated.
  final keyAllocLen = key.isEmpty ? 1 : key.length;
  final keyPtr = malloc<Uint8>(keyAllocLen);
  final dataPtr = malloc<Uint8>(data.isEmpty ? 1 : data.length);
  final out = malloc<Uint8>(size);
  final outLen = malloc<Uint32>();
  try {
    if (key.isNotEmpty) {
      keyPtr.asTypedList(key.length).setAll(0, key);
    }
    if (data.isNotEmpty) {
      dataPtr.asTypedList(data.length).setAll(0, data);
    }
    final result = HMAC(
      md,
      keyPtr.cast(),
      key.length,
      dataPtr,
      data.length,
      out,
      outLen,
    );
    if (result == nullptr) {
      throw StateError('HMAC failed: ${consumeBoringSslError()}');
    }
    return Uint8List.fromList(out.asTypedList(size));
  } finally {
    // Zeroize the key scratch buffer before it's freed, so the secret key
    // bytes don't linger in freed heap memory. BoringSSL's OPENSSL_cleanse
    // is not currently bound in ffi/libcrypto.dart, so this is a plain
    // byte-wise loop instead; it's best-effort hardening since Dart offers
    // no guaranteed-non-elided memset_s equivalent, but a loop through a
    // typed-data view over *native* memory (as opposed to a Dart-heap
    // local the compiler can prove is dead) is not elided in practice.
    // Data and digest output are not secret key material and don't need
    // this treatment.
    final keyScratch = keyPtr.asTypedList(keyAllocLen);
    for (var i = 0; i < keyScratch.length; i++) {
      keyScratch[i] = 0;
    }
    malloc
      ..free(keyPtr)
      ..free(dataPtr)
      ..free(out)
      ..free(outLen);
  }
}

/// HMAC-SHA-256 of [data] under [key] (32-byte tag).
Uint8List hmacSha256(Uint8List key, Uint8List data) =>
    _hmac(key, data, EVP_sha256(), 32);

/// HMAC-SHA-384 of [data] under [key] (48-byte tag).
Uint8List hmacSha384(Uint8List key, Uint8List data) =>
    _hmac(key, data, EVP_sha384(), 48);

/// HMAC-SHA-512 of [data] under [key] (64-byte tag).
Uint8List hmacSha512(Uint8List key, Uint8List data) =>
    _hmac(key, data, EVP_sha512(), 64);
