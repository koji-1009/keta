# keta_oidc_boringssl

The default `SignatureVerifier` implementation for keta_oidc, over `keta_native`'s BoringSSL build. `BoringSslVerifier` closes keta_oidc's `SignatureVerifier` seam with real crypto — RS256/RS384/RS512/ES256/ES384 signature checks over an audited libcrypto, plus the JOSE `r ‖ s` → DER adaptation `ES*` needs.

Depending on this package (rather than on keta_oidc alone) is what triggers the from-source BoringSSL build at hook time. keta_oidc itself stays build-free: it declares the `SignatureVerifier` seam but ships no implementation, so a consumer that brings its own verifier never pays for a BoringSSL compile.

## Usage

```dart
import 'package:keta_oidc/keta_oidc.dart';
import 'package:keta_oidc_boringssl/keta_oidc_boringssl.dart';

final validator = JwtValidator(
  verifier: BoringSslVerifier(),
  algorithms: {JwsAlgorithm.rs256},
  issuer: issuer,
  audience: audience,
);
```

A single `BoringSslVerifier` instance is meant to be shared (e.g. held by the app's `Env`): it caches each key's native conversion by `Jwk` identity, so reusing the instance avoids re-importing the same key on every verify.
