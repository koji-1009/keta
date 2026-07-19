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
  final keyPtr = malloc<Uint8>(key.isEmpty ? 1 : key.length);
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
