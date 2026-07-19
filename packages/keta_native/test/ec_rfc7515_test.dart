/// ES256 known-answer test against RFC 7515 Appendix A.3: the P-256 public key
/// (`x`, `y`), the exact JWS Signing Input octets, and the JWS Signature given
/// as the raw `R || S` pair. JOSE carries ECDSA signatures raw; keta_native
/// verifies DER, so the test converts `R || S` to DER (the caller's job) here.
library;

import 'package:keta_native/keta_native.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // RFC 7515 A.3.1 — EC JWK (public part), P-256.
  final x = b64url('f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU');
  final y = b64url('x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0');

  // RFC 7515 A.3.1 — the JWS Signing Input, i.e. ASCII of
  // BASE64URL(header) || '.' || BASE64URL(payload), verbatim from the RFC
  // (the payload carries the CR/LF that A.2 also uses).
  final signingInput = asciiBytes(
    'eyJhbGciOiJFUzI1NiJ9'
    '.'
    'eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFt'
    'cGxlLmNvbS9pc19yb290Ijp0cnVlfQ',
  );

  // RFC 7515 A.3.1 — the signature as the raw (R || S) pair.
  final rawSignature = bytesOf(const [
    // R
    14, 209, 33, 83, 121, 99, 108, 72, 60, 47, 127, 21, 88, 7, 212, 2, //
    163, 178, 40, 3, 58, 249, 124, 126, 23, 129, 154, 195, 22, 158, 166, 101,
    // S
    197, 10, 7, 211, 140, 60, 112, 229, 216, 241, 45, 175, 8, 74, 84, 128,
    166, 101, 144, 197, 242, 147, 80, 154, 143, 63, 127, 138, 131, 163, 84,
    213,
  ]);

  test('ES256 verifies the RFC 7515 A.3 signature (raw R||S -> DER)', () {
    final key = EcPublicKey.p256(x, y);
    final der = rawEcdsaSignatureToDer(rawSignature);
    expect(key.verifyEcdsaSha256(signingInput, der), isTrue);
  });

  test('ES256 rejects a tampered signing input', () {
    final key = EcPublicKey.p256(x, y);
    final der = rawEcdsaSignatureToDer(rawSignature);
    final tampered = bytesOf(signingInput)..[0] ^= 0x01;
    expect(key.verifyEcdsaSha256(tampered, der), isFalse);
  });

  test('ES256 rejects a tampered signature (S flipped)', () {
    final key = EcPublicKey.p256(x, y);
    final tampered = bytesOf(rawSignature)..[63] ^= 0x01;
    final der = rawEcdsaSignatureToDer(tampered);
    expect(key.verifyEcdsaSha256(signingInput, der), isFalse);
  });

  test('ES256 rejects a non-DER (raw) signature without throwing', () {
    final key = EcPublicKey.p256(x, y);
    // Passing the raw r||s where DER is expected must fail closed, not throw.
    expect(key.verifyEcdsaSha256(signingInput, rawSignature), isFalse);
  });
}
