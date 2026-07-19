/// Test support for keta_native: key generation and signing, kept out of the
/// verify-only production surface in `package:keta_native/keta_native.dart`.
///
/// [RsaKeyPair] and [EcKeyPair] mint fresh keys, sign messages (mirroring the
/// verify algorithms), and expose their public components as JWK-shaped
/// big-endian bytes (`n`/`e`, `x`/`y`) so JWKS fixtures can be assembled. Each
/// pair's matching verify-only public key is available via `publicKey()`.
///
/// This library is for tests and fixtures. Nothing here belongs on a
/// production request path.
library;

export 'src/testing_keys.dart' show EcKeyPair, RsaKeyPair;
