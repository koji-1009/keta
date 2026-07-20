/// The C symbols the link hook keeps when tree-shaking `libcrypto`.
///
/// Must list exactly the `symbol:` names of the `@Native` bindings in
/// `lib/src/ffi/libcrypto.dart`: a binding missing here still resolves in JIT
/// runs (which bundle the full library) but fails at load time in linked AOT
/// builds. `test/symbols_test.dart` forces the two into agreement.
library;

const List<String> symbols = [
  'BN_bin2bn',
  'BN_bn2bin',
  'BN_free',
  'BN_new',
  'BN_num_bytes',
  'BN_set_word',
  'EC_KEY_free',
  'EC_KEY_generate_key',
  'EC_KEY_get0_group',
  'EC_KEY_get0_public_key',
  'EC_KEY_new_by_curve_name',
  'EC_KEY_set_public_key_affine_coordinates',
  'EC_POINT_get_affine_coordinates_GFp',
  'ERR_clear_error',
  'ERR_error_string_n',
  'ERR_get_error',
  'EVP_Digest',
  'EVP_DigestSign',
  'EVP_DigestSignInit',
  'EVP_DigestVerify',
  'EVP_DigestVerifyInit',
  'EVP_MD_CTX_free',
  'EVP_MD_CTX_new',
  'EVP_PKEY_assign_EC_KEY',
  'EVP_PKEY_assign_RSA',
  'EVP_PKEY_free',
  'EVP_PKEY_new',
  'EVP_sha256',
  'EVP_sha384',
  'EVP_sha512',
  'HMAC',
  'RSA_free',
  'RSA_generate_key_ex',
  'RSA_get0_e',
  'RSA_get0_n',
  'RSA_new',
  'RSA_new_public_key',
];
