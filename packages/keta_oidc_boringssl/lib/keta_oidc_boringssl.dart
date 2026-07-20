/// The production `SignatureVerifier` for keta_oidc: [BoringSslVerifier],
/// backed by BoringSSL through `package:keta_native`. keta_oidc's JWT core
/// carries no crypto dependency of its own — this package closes the
/// `SignatureVerifier` seam with real crypto, so depending on it (rather than
/// on keta_oidc alone) is what pulls the BoringSSL from-source build in.
library;

export 'src/boringssl_verifier.dart' show BoringSslVerifier;
