/// The git commit of google/boringssl that this package's `libcrypto` is
/// built from.
///
/// Mirrors `hook/boringssl_commit.txt`, the pin the build hook fetches and
/// compiles; `test/version_test.dart` fails if the two drift. Embedding
/// programs can read this constant to report or audit which BoringSSL
/// revision backs the crypto.
const String boringsslCommit = '922c15f36cc75db5af33c46f9ea8934553fb808e';
