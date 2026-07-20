# keta_native

The standalone native crypto layer beside keta — it depends on nothing in the workspace, so it carries no ring; outer packages pull it in with the same standing as a third-party dependency. It builds BoringSSL's `libcrypto` from a pinned source commit at hook (native-assets) time and exposes a small, hand-written FFI surface over the verify-oriented primitives keta needs — SHA-2 digests, HMAC, and RSA/ECDSA signature verification. It owns exactly one idea: give the pure-Dart rings a fast, correct, standards-backed verifier without shelling out or trusting a hand-rolled big-integer implementation.

Its first consumer is `keta_oidc_boringssl`'s `BoringSslVerifier`, the default signature backend for keta_oidc's JWT resource-server path, which validates inbound tokens. That path needs to *verify* signatures and compute HMACs, not mint keys or issue tokens — so the production surface is verification-only, and everything that signs lives behind a separate `testing.dart` import.

## Why a source build, and why pinned

The Dart VM already embeds BoringSSL statically, but those symbols are private to the VM and not a supported FFI target. keta_native therefore compiles its **own** copy of `libcrypto` into a per-asset dynamic library that the `@Native` bindings load directly. The two copies are independent — macOS resolves symbols with a two-level namespace and the dylib links no BoringSSL of its own (only `libc++` and `libSystem`), so there is no collision with the VM's embedded copy.

The source is fetched from **google/boringssl at the commit pinned in `hook/boringssl_commit.txt`** (`main`, 2026-07-17). Pinning a commit — rather than tracking a branch or a distro package — makes the build reproducible and puts every byte of the crypto under version control review. The pin is a data file, not a constant in hook code: bumping BoringSSL is a one-line change, the file is registered as a hook dependency so the native-assets cache invalidates exactly when it changes, and the same commit is exposed to Dart as `boringsslCommit` with a test that fails if the two drift. At the pinned commit `gen/sources.json` is checked in, so the file list is read straight from the tree with **no perl/go/cmake/nasm generation step**; the hook needs only `tar` and a C/C++ toolchain (clang). The build:

1. Downloads the pinned commit's source tarball — one HTTPS GET against GitHub's commit-addressed archive endpoint, served from the download path (codeload) rather than the git backend, so it needs no git binary and passes plain HTTP proxies and caches — into the hook's shared output directory, and records it in a marker file. Later builds skip the fetch when the marker matches, so only the first build touches the network.
2. Compiles the `bcm` and `crypto` targets from `gen/sources.json` (1 + 243 C++ translation units plus their per-arch `.S` assembly) into one `libcrypto`, matching the non-FIPS library CMake builds from the same lists. Build flags are taken from BoringSSL's `CMakeLists.txt` and pinned with a comment at each site (`-std=c++17`, `-DBORINGSSL_IMPLEMENTATION`, `-fno-exceptions -fno-rtti`, and `-D_XOPEN_SOURCE=700` on Linux), plus `-ffunction-sections -fdata-sections` so the link step can strip at symbol granularity.
3. Emits the result in one of two modes. With linking enabled (AOT `dart build`), the compile produces a static archive routed to the in-package link hook (`hook/link.dart`), which tree-shakes it to exactly the symbols the `@Native` bindings reference — the keep-list is derived at link time from the bindings file itself, never hand-listed, and a binding that does not name its C symbol explicitly fails the build — so the deployed library carries only the BoringSSL code reachable from the bound symbols. When the AOT compile records usages (the `record-use` experiment), the keep-list narrows further to the bindings the app actually reaches — a verify-only binary carries no key-generation or signing code; a build without recordings keeps every binding. (Dart 3.12 stable does not yet deliver recordings to link hooks, so today every build takes the full-surface path.) Without link hooks (JIT: `dart test` / `dart run`), the full `libcrypto` ships as the dynamic library.

The first build compiles ~370 translation units and takes a while; subsequent builds hit the native-assets cache.

## Platform matrix

**macOS and Linux only.** The build hook fails with a clear error on any other target OS. keta is a server framework, and these are the platforms it serves on. The `.S` assembly files carry platform preprocessor guards, so the whole set is handed to clang on any macOS/Linux target and the non-matching files assemble to empty objects.

## Public API (`package:keta_native/keta_native.dart`)

All inputs and outputs are `Uint8List` of raw bytes.

- `sha256` / `sha384` / `sha512` — one-shot SHA-2 digests.
- `hmacSha256` / `hmacSha384` / `hmacSha512` — one-shot HMAC.
- `RsaPublicKey.fromComponents(modulus, exponent)` — from JWK-shaped big-endian `n`/`e`; `verifyPkcs1Sha256/384/512` implement JOSE `RS256/384/512` (RSASSA-PKCS1-v1_5 over the message).
- `EcPublicKey.p256(x, y)` / `EcPublicKey.p384(x, y)` — from big-endian affine coordinates; `verifyEcdsaSha256/384` implement `ES256/384`.
- `boringsslCommit` — the pinned google/boringssl commit the library is built from, for reporting or auditing.

**ECDSA signatures are DER.** The verify methods take a DER-encoded `SEQUENCE { r, s }`. JOSE carries the signature as the raw fixed-width `r || s` concatenation, so converting raw→DER is the caller's job (`keta_oidc_boringssl` does this for JWS) — keta_native deliberately does not guess an encoding.

### Error posture

- Malformed key material (empty modulus, zero exponent, wrong-length or off-curve coordinates) throws **`ArgumentError`**, carrying the BoringSSL error string.
- A signature that does not verify returns **`false`** and never throws — a mismatch, a wrong key, and a malformed signature all fail closed.
- Any genuinely impossible native state throws **`StateError`**.

Long-lived key handles (`EVP_PKEY`) free their native memory through a `NativeFinalizer` on garbage collection; there is no `close()` to call. Every temporary native object is freed on all paths, and the BoringSSL error queue is drained wherever an error is consumed so state never leaks between calls.

## Test support (`package:keta_native/testing.dart`)

`RsaKeyPair.generate([bits = 2048])`, `EcKeyPair.generateP256()`, and `EcKeyPair.generateP384()` mint fresh keys, sign (mirroring the verify algorithms), and expose their public components as JWK-shaped big-endian bytes (`n`/`e`, `x`/`y`) so JWKS fixtures can be built. Each pair's matching verify-only public key is available via `publicKey()`. This library is for tests and fixtures; nothing here belongs on a request path.

## Judged absences

These are deliberate, not TODOs:

- **No signing in the public API.** A resource server verifies; it does not hold signing keys. Signing exists only under `testing.dart`, for tests. An issuer (were keta to grow one) would be a separate, deliberately-scoped surface.
- **No PS\* (RSA-PSS) or HS\* JWS algorithms as key types.** The public surface covers the digests and HMACs directly and the two signature families JWKS-based resource servers overwhelmingly use (`RS*`, `ES*`). HMAC-based JWS (`HS*`) is built from the exposed `hmacSha*` primitives at the JOSE layer; RSA-PSS is not wired here until a consumer needs it. The BoringSSL build underneath supports far more than is surfaced — the surface is kept to what has a caller.
- **No Windows, no mobile.** Server platforms only; see the platform matrix.

## Tests

Every claim is exercised: SHA-2 and HMAC against NIST / RFC 4231 known-answer vectors; `RS256` against RFC 7515 Appendix A.2, `ES256` against Appendix A.3 (the raw `r || s` converted to DER inside the test), and `ES384` against a Google Wycheproof P-384/SHA-384 vector (DER as shipped); round-trips through `testing.dart` for every algorithm (sign→verify true, tampered message/signature and wrong key → false); malformed-key rejection; and a several-thousand-iteration verify loop as an error-queue/leak sanity check.
