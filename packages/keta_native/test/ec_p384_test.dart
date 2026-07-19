/// ES384 known-answer test on NIST P-384, sourced from Google Wycheproof
/// (`ecdsa_secp384r1_sha384_test.json`, testvectors_v1). Wycheproof carries the
/// signature already DER-encoded, which is exactly what [EcPublicKey.verifyEcdsaSha384]
/// takes, so the vector is used directly.
library;

import 'package:keta_native/keta_native.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // Public key (affine coordinates, big-endian, 48 bytes each).
  final x = hex(
    '29bdb76d5fa741bfd70233cb3a66cc7d44beb3b0663d92a8136650478bcefb61'
    'ef182e155a54345a5e8e5e88f064e5bc',
  );
  final y = hex(
    '9a525ab7f764dad3dae1468c2b419f3b62b9ba917d5e8c4fb1ec47404a3fc764'
    '74b2713081be9db4c00e043ada9fc4a3',
  );

  // Wycheproof tcId 2: message "Msg", a valid DER-encoded signature.
  final message = hex('4d7367');
  final derSignature = hex(
    '3066023100d7143a836608b25599a7f28dec6635494c2992ad1e2bbeecb7ef601'
    'a9c01746e710ce0d9c48accb38a79ede5b9638f3402310080f9e165e8c61035bf'
    '8aa7b5533960e46dd0e211c904a064edb6de41f797c0eae4e327612ee3f816f41'
    '57272bb4fabc9',
  );

  test('ES384 verifies the Wycheproof P-384/SHA-384 signature', () {
    final key = EcPublicKey.p384(x, y);
    expect(key.verifyEcdsaSha384(message, derSignature), isTrue);
  });

  test('ES384 rejects a tampered message', () {
    final key = EcPublicKey.p384(x, y);
    final tampered = bytesOf(message)..[0] ^= 0x01;
    expect(key.verifyEcdsaSha384(tampered, derSignature), isFalse);
  });

  test('ES384 rejects a tampered signature', () {
    final key = EcPublicKey.p384(x, y);
    // Flip a byte deep in the DER value (past the SEQUENCE + first INTEGER
    // header) so the structure stays parseable but r is wrong.
    final tampered = bytesOf(derSignature)..[8] ^= 0x01;
    expect(key.verifyEcdsaSha384(message, tampered), isFalse);
  });
}
