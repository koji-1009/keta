library;

import 'dart:typed_data';

import 'algorithm.dart';
import 'jwk.dart';

/// The seam between the JWT layer and the cryptographic backend that checks a
/// signature. keta_oidc's JWT core does all of its work — parsing, the
/// algorithm allowlist, claims validation — without any crypto dependency, and
/// calls through this one method for the single operation that needs one.
///
/// The initial backend is BoringSSL (built in `keta_native`), but the seam
/// exists so it can be swapped: the JWT layer depends on this interface, never
/// on a concrete backend.
///
/// ## Contract
///
/// [verify] returns `true` iff [signature] is a valid signature over
/// [signingInput] under [algorithm] for the public key in [key]. It **returns**
/// `false` for a signature that simply does not verify — a non-verifying
/// signature is an ordinary, expected outcome, not an error. It may **throw**
/// only for a backend-level defect (a key it cannot import, an internal crypto
/// failure); those are author/environment defects, surfaced as thrown errors,
/// never as a silent `false`.
///
/// ## Byte forms that cross the seam
///
/// * [signingInput] is the ASCII bytes of `"<header>.<payload>"` — the first two
///   compact segments joined by the dot, exactly as they appeared on the wire.
///   The verifier hashes and verifies **these** bytes; it does not re-encode
///   anything.
/// * [signature] is the **raw JOSE signature**, decoded straight from the third
///   compact segment:
///   * for RSA (`RS*`), the PKCS#1 v1.5 signature octets;
///   * for ECDSA (`ES*`), the **fixed-width `r ‖ s`** concatenation JOSE
///     mandates (RFC 7518 §3.4) — *not* the ASN.1/DER `SEQUENCE` some crypto
///     libraries expect. A backend that needs DER (OpenSSL/BoringSSL's
///     `ECDSA_verify` does) converts `r ‖ s` to DER itself. Fixing the JOSE-side
///     representation as the thing that crosses the seam keeps every backend
///     interchangeable and this contract unambiguous.
///
/// ## Keys are long-lived
///
/// The same [Jwk] instance is reused across calls (the JWKS cache hands out one
/// instance per key). A backend that converts [key] into a native key object
/// MAY cache that conversion keyed on [Jwk] identity — an [Expando] over [key]
/// — rather than re-importing the raw components on every call. See [Jwk].
abstract interface class SignatureVerifier {
  /// Returns `true` iff [signature] verifies over [signingInput] under
  /// [algorithm] for [key]; returns `false` for a signature that does not
  /// verify. Throws only on a backend defect (e.g. a key it cannot import).
  bool verify({
    required Jwk key,
    required JwsAlgorithm algorithm,
    required Uint8List signingInput,
    required Uint8List signature,
  });
}
