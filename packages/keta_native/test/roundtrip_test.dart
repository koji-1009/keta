/// Round-trip tests via the test-support key generators: for every supported
/// algorithm, a freshly generated key signs and its public half verifies;
/// a tampered message, a tampered signature, and a wrong key all verify false.
library;

import 'dart:typed_data';

import 'package:keta_native/keta_native.dart';
import 'package:keta_native/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final message = asciiBytes('the quick brown fox jumps over the lazy dog');

  Uint8List flip(Uint8List source, int index) =>
      bytesOf(source)..[index] ^= 0x01;

  group('RSA RS256/384/512 round-trips', () {
    late RsaKeyPair pair;
    late RsaKeyPair other;
    setUpAll(() {
      // One 2048-bit generation, reused across the alg variants (keygen is the
      // slow part; verification is what we are exercising per case).
      pair = RsaKeyPair.generate();
      other = RsaKeyPair.generate();
    });

    final variants =
        <
          (
            String,
            Uint8List Function(RsaKeyPair, Uint8List),
            bool Function(RsaPublicKey, Uint8List, Uint8List),
          )
        >[
          (
            'RS256',
            (k, m) => k.signPkcs1Sha256(m),
            (k, m, s) => k.verifyPkcs1Sha256(m, s),
          ),
          (
            'RS384',
            (k, m) => k.signPkcs1Sha384(m),
            (k, m, s) => k.verifyPkcs1Sha384(m, s),
          ),
          (
            'RS512',
            (k, m) => k.signPkcs1Sha512(m),
            (k, m, s) => k.verifyPkcs1Sha512(m, s),
          ),
        ];

    for (final (label, sign, verify) in variants) {
      group(label, () {
        test('sign then verify is true', () {
          final sig = sign(pair, message);
          expect(verify(pair.publicKey(), message, sig), isTrue);
        });
        test('tampered message verifies false', () {
          final sig = sign(pair, message);
          expect(verify(pair.publicKey(), flip(message, 3), sig), isFalse);
        });
        test('tampered signature verifies false', () {
          final sig = sign(pair, message);
          expect(verify(pair.publicKey(), message, flip(sig, 10)), isFalse);
        });
        test('wrong key verifies false', () {
          final sig = sign(pair, message);
          expect(verify(other.publicKey(), message, sig), isFalse);
        });
      });
    }

    test('the exposed n/e rebuild the same verifying key', () {
      final rebuilt = RsaPublicKey.fromComponents(pair.modulus, pair.exponent);
      expect(
        rebuilt.verifyPkcs1Sha256(message, pair.signPkcs1Sha256(message)),
        isTrue,
      );
      // e for the F4 exponent is the canonical AQAB / 0x010001.
      expect(toHex(pair.exponent), '010001');
    });
  });

  group('EC ES256 round-trips (P-256)', () {
    late EcKeyPair pair;
    late EcKeyPair other;
    setUpAll(() {
      pair = EcKeyPair.generateP256();
      other = EcKeyPair.generateP256();
    });

    test('sign then verify is true', () {
      final sig = pair.signEcdsaSha256(message);
      expect(pair.publicKey().verifyEcdsaSha256(message, sig), isTrue);
    });
    test('tampered message verifies false', () {
      final sig = pair.signEcdsaSha256(message);
      expect(
        pair.publicKey().verifyEcdsaSha256(flip(message, 5), sig),
        isFalse,
      );
    });
    test('tampered signature verifies false', () {
      final sig = pair.signEcdsaSha256(message);
      // Flip a byte deep in the DER value (past the header) to keep it parseable
      // but wrong.
      expect(
        pair.publicKey().verifyEcdsaSha256(message, flip(sig, sig.length - 1)),
        isFalse,
      );
    });
    test('wrong key verifies false', () {
      final sig = pair.signEcdsaSha256(message);
      expect(other.publicKey().verifyEcdsaSha256(message, sig), isFalse);
    });
    test('x/y are 32-byte P-256 coordinates and rebuild the key', () {
      expect(pair.x.length, 32);
      expect(pair.y.length, 32);
      final rebuilt = EcPublicKey.p256(pair.x, pair.y);
      expect(
        rebuilt.verifyEcdsaSha256(message, pair.signEcdsaSha256(message)),
        isTrue,
      );
    });
  });

  group('EC ES384 round-trips (P-384)', () {
    late EcKeyPair pair;
    late EcKeyPair other;
    setUpAll(() {
      pair = EcKeyPair.generateP384();
      other = EcKeyPair.generateP384();
    });

    test('sign then verify is true', () {
      final sig = pair.signEcdsaSha384(message);
      expect(pair.publicKey().verifyEcdsaSha384(message, sig), isTrue);
    });
    test('tampered message verifies false', () {
      final sig = pair.signEcdsaSha384(message);
      expect(
        pair.publicKey().verifyEcdsaSha384(flip(message, 5), sig),
        isFalse,
      );
    });
    test('tampered signature verifies false', () {
      final sig = pair.signEcdsaSha384(message);
      expect(
        pair.publicKey().verifyEcdsaSha384(message, flip(sig, sig.length - 1)),
        isFalse,
      );
    });
    test('wrong key verifies false', () {
      final sig = pair.signEcdsaSha384(message);
      expect(other.publicKey().verifyEcdsaSha384(message, sig), isFalse);
    });
    test('x/y are 48-byte P-384 coordinates and rebuild the key', () {
      expect(pair.x.length, 48);
      expect(pair.y.length, 48);
      final rebuilt = EcPublicKey.p384(pair.x, pair.y);
      expect(
        rebuilt.verifyEcdsaSha384(message, pair.signEcdsaSha384(message)),
        isTrue,
      );
    });
  });
}
