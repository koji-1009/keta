/// Hand-written `@Native` bindings to the subset of BoringSSL's libcrypto that
/// keta_native uses. No codegen: every declaration below is written and
/// maintained by hand, and its native signature is pinned against the headers
/// of the BoringSSL commit compiled by `hook/build.dart`.
///
/// This library's URI must match the `assetName` the build hook gives the
/// compiled dynamic library (`src/ffi/libcrypto.dart`) so that the default
/// asset id of each `@Native` external resolves to that dylib.
///
/// The C API keeps its original names here so the bindings read against the
/// BoringSSL headers; hence the file-level lint ignore.
///
/// Every binding carries `@RecordUse()` beside `@Native`: an AOT build with
/// the `record-use` experiment records which bindings the app actually
/// reaches, and the link hook narrows its tree-shake keep-list to exactly
/// those. `hook/symbols.dart` fails the build if a binding misses either
/// annotation or the explicit `symbol:`.
///
/// **`isLeaf` policy.** A leaf call keeps the thread in generated-Dart state:
/// the VM cannot reach a safepoint until it returns, so GC for the whole
/// isolate group waits on it — and keta runs `serve(isolates: n)` over one
/// shared group. `isLeaf: true` is therefore used ONLY for calls with a
/// bounded, tiny runtime (the digest-algorithm getters, handle
/// new/free/assign, BIGNUM ops, RSA/EC accessors, the error queue). Any call
/// whose duration is unbounded or input-proportional — key generation, and the
/// one-shot digest/HMAC/sign/verify calls that scale with the message — is
/// left non-leaf; its few-nanosecond transition cost is irrelevant next to the
/// crypto work, and it lets the isolate group collect while it runs.
// ignore_for_file: non_constant_identifier_names, camel_case_types
// ignore_for_file: constant_identifier_names
library;

import 'dart:ffi';

import 'package:meta/meta.dart' show RecordUse;

// --- Opaque handle types (never dereferenced from Dart) --------------------

final class EVP_MD extends Opaque {}

final class EVP_MD_CTX extends Opaque {}

final class EVP_PKEY extends Opaque {}

final class RSA extends Opaque {}

final class EC_KEY extends Opaque {}

final class EC_GROUP extends Opaque {}

final class EC_POINT extends Opaque {}

final class BIGNUM extends Opaque {}

// --- Curve NIDs (include/openssl/nid.h) ------------------------------------

/// NID for the NIST P-256 curve (a.k.a. prime256v1 / secp256r1).
const int NID_X9_62_prime256v1 = 415;

/// NID for the NIST P-384 curve (secp384r1).
const int NID_secp384r1 = 715;

// --- Digests (include/openssl/digest.h) ------------------------------------

@RecordUse()
@Native<Pointer<EVP_MD> Function()>(symbol: 'EVP_sha256', isLeaf: true)
external Pointer<EVP_MD> EVP_sha256();

@RecordUse()
@Native<Pointer<EVP_MD> Function()>(symbol: 'EVP_sha384', isLeaf: true)
external Pointer<EVP_MD> EVP_sha384();

@RecordUse()
@Native<Pointer<EVP_MD> Function()>(symbol: 'EVP_sha512', isLeaf: true)
external Pointer<EVP_MD> EVP_sha512();

// Non-leaf: runtime scales with the message length (see isLeaf policy above).
@RecordUse()
@Native<
  Int Function(
    Pointer<Void>,
    Size,
    Pointer<Uint8>,
    Pointer<Uint32>,
    Pointer<EVP_MD>,
    Pointer<Void>,
  )
>(symbol: 'EVP_Digest')
external int EVP_Digest(
  Pointer<Void> data,
  int len,
  Pointer<Uint8> mdOut,
  Pointer<Uint32> mdOutSize,
  Pointer<EVP_MD> type,
  Pointer<Void> engine,
);

@RecordUse()
@Native<Pointer<EVP_MD_CTX> Function()>(symbol: 'EVP_MD_CTX_new', isLeaf: true)
external Pointer<EVP_MD_CTX> EVP_MD_CTX_new();

@RecordUse()
@Native<Void Function(Pointer<EVP_MD_CTX>)>(
  symbol: 'EVP_MD_CTX_free',
  isLeaf: true,
)
external void EVP_MD_CTX_free(Pointer<EVP_MD_CTX> ctx);

// --- HMAC (include/openssl/hmac.h) -----------------------------------------

// Non-leaf: runtime scales with the message length (see isLeaf policy above).
@RecordUse()
@Native<
  Pointer<Uint8> Function(
    Pointer<EVP_MD>,
    Pointer<Void>,
    Size,
    Pointer<Uint8>,
    Size,
    Pointer<Uint8>,
    Pointer<Uint32>,
  )
>(symbol: 'HMAC')
external Pointer<Uint8> HMAC(
  Pointer<EVP_MD> evpMd,
  Pointer<Void> key,
  int keyLen,
  Pointer<Uint8> data,
  int dataLen,
  Pointer<Uint8> out,
  Pointer<Uint32> outLen,
);

// --- EVP_PKEY (include/openssl/evp.h) --------------------------------------

@RecordUse()
@Native<Pointer<EVP_PKEY> Function()>(symbol: 'EVP_PKEY_new', isLeaf: true)
external Pointer<EVP_PKEY> EVP_PKEY_new();

@RecordUse()
@Native<Void Function(Pointer<EVP_PKEY>)>(symbol: 'EVP_PKEY_free', isLeaf: true)
external void EVP_PKEY_free(Pointer<EVP_PKEY> pkey);

@RecordUse()
@Native<Int Function(Pointer<EVP_PKEY>, Pointer<RSA>)>(
  symbol: 'EVP_PKEY_assign_RSA',
  isLeaf: true,
)
external int EVP_PKEY_assign_RSA(Pointer<EVP_PKEY> pkey, Pointer<RSA> key);

@RecordUse()
@Native<Int Function(Pointer<EVP_PKEY>, Pointer<EC_KEY>)>(
  symbol: 'EVP_PKEY_assign_EC_KEY',
  isLeaf: true,
)
external int EVP_PKEY_assign_EC_KEY(
  Pointer<EVP_PKEY> pkey,
  Pointer<EC_KEY> key,
);

@RecordUse()
@Native<
  Int Function(
    Pointer<EVP_MD_CTX>,
    Pointer<Pointer<Void>>,
    Pointer<EVP_MD>,
    Pointer<Void>,
    Pointer<EVP_PKEY>,
  )
>(symbol: 'EVP_DigestVerifyInit', isLeaf: true)
external int EVP_DigestVerifyInit(
  Pointer<EVP_MD_CTX> ctx,
  Pointer<Pointer<Void>> pctx,
  Pointer<EVP_MD> type,
  Pointer<Void> engine,
  Pointer<EVP_PKEY> pkey,
);

// Non-leaf: runtime scales with the message length (see isLeaf policy above).
@RecordUse()
@Native<
  Int Function(Pointer<EVP_MD_CTX>, Pointer<Uint8>, Size, Pointer<Uint8>, Size)
>(symbol: 'EVP_DigestVerify')
external int EVP_DigestVerify(
  Pointer<EVP_MD_CTX> ctx,
  Pointer<Uint8> sig,
  int sigLen,
  Pointer<Uint8> data,
  int dataLen,
);

@RecordUse()
@Native<
  Int Function(
    Pointer<EVP_MD_CTX>,
    Pointer<Pointer<Void>>,
    Pointer<EVP_MD>,
    Pointer<Void>,
    Pointer<EVP_PKEY>,
  )
>(symbol: 'EVP_DigestSignInit', isLeaf: true)
external int EVP_DigestSignInit(
  Pointer<EVP_MD_CTX> ctx,
  Pointer<Pointer<Void>> pctx,
  Pointer<EVP_MD> type,
  Pointer<Void> engine,
  Pointer<EVP_PKEY> pkey,
);

// Non-leaf: runtime scales with the message length (see isLeaf policy above).
@RecordUse()
@Native<
  Int Function(
    Pointer<EVP_MD_CTX>,
    Pointer<Uint8>,
    Pointer<Size>,
    Pointer<Uint8>,
    Size,
  )
>(symbol: 'EVP_DigestSign')
external int EVP_DigestSign(
  Pointer<EVP_MD_CTX> ctx,
  Pointer<Uint8> outSig,
  Pointer<Size> outSigLen,
  Pointer<Uint8> data,
  int dataLen,
);

// --- RSA (include/openssl/rsa.h) -------------------------------------------

@RecordUse()
@Native<Pointer<RSA> Function(Pointer<BIGNUM>, Pointer<BIGNUM>)>(
  symbol: 'RSA_new_public_key',
  isLeaf: true,
)
external Pointer<RSA> RSA_new_public_key(Pointer<BIGNUM> n, Pointer<BIGNUM> e);

@RecordUse()
@Native<Pointer<RSA> Function()>(symbol: 'RSA_new', isLeaf: true)
external Pointer<RSA> RSA_new();

@RecordUse()
@Native<Void Function(Pointer<RSA>)>(symbol: 'RSA_free', isLeaf: true)
external void RSA_free(Pointer<RSA> rsa);

// Non-leaf: probabilistic prime search, occasionally hundreds of ms (see
// isLeaf policy above).
@RecordUse()
@Native<Int Function(Pointer<RSA>, Int, Pointer<BIGNUM>, Pointer<Void>)>(
  symbol: 'RSA_generate_key_ex',
)
external int RSA_generate_key_ex(
  Pointer<RSA> rsa,
  int bits,
  Pointer<BIGNUM> e,
  Pointer<Void> cb,
);

@RecordUse()
@Native<Pointer<BIGNUM> Function(Pointer<RSA>)>(
  symbol: 'RSA_get0_n',
  isLeaf: true,
)
external Pointer<BIGNUM> RSA_get0_n(Pointer<RSA> rsa);

@RecordUse()
@Native<Pointer<BIGNUM> Function(Pointer<RSA>)>(
  symbol: 'RSA_get0_e',
  isLeaf: true,
)
external Pointer<BIGNUM> RSA_get0_e(Pointer<RSA> rsa);

// --- EC (include/openssl/ec.h, ec_key.h) -----------------------------------

@RecordUse()
@Native<Pointer<EC_KEY> Function(Int)>(
  symbol: 'EC_KEY_new_by_curve_name',
  isLeaf: true,
)
external Pointer<EC_KEY> EC_KEY_new_by_curve_name(int nid);

@RecordUse()
@Native<Void Function(Pointer<EC_KEY>)>(symbol: 'EC_KEY_free', isLeaf: true)
external void EC_KEY_free(Pointer<EC_KEY> key);

// Non-leaf: unbounded runtime, not bounded-tiny (see isLeaf policy above).
@RecordUse()
@Native<Int Function(Pointer<EC_KEY>)>(symbol: 'EC_KEY_generate_key')
external int EC_KEY_generate_key(Pointer<EC_KEY> key);

@RecordUse()
@Native<Int Function(Pointer<EC_KEY>, Pointer<BIGNUM>, Pointer<BIGNUM>)>(
  symbol: 'EC_KEY_set_public_key_affine_coordinates',
  isLeaf: true,
)
external int EC_KEY_set_public_key_affine_coordinates(
  Pointer<EC_KEY> key,
  Pointer<BIGNUM> x,
  Pointer<BIGNUM> y,
);

@RecordUse()
@Native<Pointer<EC_GROUP> Function(Pointer<EC_KEY>)>(
  symbol: 'EC_KEY_get0_group',
  isLeaf: true,
)
external Pointer<EC_GROUP> EC_KEY_get0_group(Pointer<EC_KEY> key);

@RecordUse()
@Native<Pointer<EC_POINT> Function(Pointer<EC_KEY>)>(
  symbol: 'EC_KEY_get0_public_key',
  isLeaf: true,
)
external Pointer<EC_POINT> EC_KEY_get0_public_key(Pointer<EC_KEY> key);

@RecordUse()
@Native<
  Int Function(
    Pointer<EC_GROUP>,
    Pointer<EC_POINT>,
    Pointer<BIGNUM>,
    Pointer<BIGNUM>,
    Pointer<Void>,
  )
>(symbol: 'EC_POINT_get_affine_coordinates_GFp', isLeaf: true)
external int EC_POINT_get_affine_coordinates_GFp(
  Pointer<EC_GROUP> group,
  Pointer<EC_POINT> point,
  Pointer<BIGNUM> x,
  Pointer<BIGNUM> y,
  Pointer<Void> ctx,
);

// --- BIGNUM (include/openssl/bn.h) -----------------------------------------

@RecordUse()
@Native<Pointer<BIGNUM> Function()>(symbol: 'BN_new', isLeaf: true)
external Pointer<BIGNUM> BN_new();

@RecordUse()
@Native<Void Function(Pointer<BIGNUM>)>(symbol: 'BN_free', isLeaf: true)
external void BN_free(Pointer<BIGNUM> bn);

@RecordUse()
@Native<Pointer<BIGNUM> Function(Pointer<Uint8>, Size, Pointer<BIGNUM>)>(
  symbol: 'BN_bin2bn',
  isLeaf: true,
)
external Pointer<BIGNUM> BN_bin2bn(
  Pointer<Uint8> data,
  int len,
  Pointer<BIGNUM> ret,
);

@RecordUse()
@Native<Size Function(Pointer<BIGNUM>, Pointer<Uint8>)>(
  symbol: 'BN_bn2bin',
  isLeaf: true,
)
external int BN_bn2bin(Pointer<BIGNUM> bn, Pointer<Uint8> out);

@RecordUse()
@Native<UnsignedInt Function(Pointer<BIGNUM>)>(
  symbol: 'BN_num_bytes',
  isLeaf: true,
)
external int BN_num_bytes(Pointer<BIGNUM> bn);

@RecordUse()
@Native<Int Function(Pointer<BIGNUM>, UnsignedLong)>(
  symbol: 'BN_set_word',
  isLeaf: true,
)
external int BN_set_word(Pointer<BIGNUM> bn, int value);

// --- Error queue (include/openssl/err.h) -----------------------------------

@RecordUse()
@Native<Uint32 Function()>(symbol: 'ERR_get_error', isLeaf: true)
external int ERR_get_error();

@RecordUse()
@Native<Pointer<Uint8> Function(Uint32, Pointer<Uint8>, Size)>(
  symbol: 'ERR_error_string_n',
  isLeaf: true,
)
external Pointer<Uint8> ERR_error_string_n(
  int packedError,
  Pointer<Uint8> buf,
  int len,
);

@RecordUse()
@Native<Void Function()>(symbol: 'ERR_clear_error', isLeaf: true)
external void ERR_clear_error();
