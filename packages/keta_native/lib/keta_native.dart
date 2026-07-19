/// keta_native — the Ring 3 native crypto layer for keta, built on BoringSSL's
/// libcrypto (compiled from a pinned commit at hook / native-assets build
/// time). It exposes a small, **verification-oriented** surface:
///
/// - SHA-2 digests: [sha256], [sha384], [sha512].
/// - HMAC-SHA-2: [hmacSha256], [hmacSha384], [hmacSha512].
/// - RSASSA-PKCS1-v1_5 verification via [RsaPublicKey] (JOSE `RS256/384/512`).
/// - ECDSA verification via [EcPublicKey] on P-256 / P-384 (`ES256` / `ES384`).
///
/// The first consumer is keta_oidc's JWT resource-server path, which needs to
/// *verify* tokens, not issue them — so there is deliberately no signing here.
/// Key generation and signing live in `package:keta_native/testing.dart` for
/// tests and fixtures only.
///
/// **Error posture.** Malformed key material throws [ArgumentError] carrying
/// the BoringSSL error string; a signature that does not verify returns `false`
/// and never throws. Long-lived key handles free their native memory on
/// garbage collection (a [NativeFinalizer]); no `close()` is required.
///
/// **Platform matrix.** macOS and Linux only. See the package README.
library;

export 'src/digest.dart'
    show hmacSha256, hmacSha384, hmacSha512, sha256, sha384, sha512;
export 'src/ec.dart' show EcPublicKey;
export 'src/rsa.dart' show RsaPublicKey;
