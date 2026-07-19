/// Pins the JOSE `r ‖ s` → DER encoder in isolation: it round-trips real
/// BoringSSL ECDSA signatures, strips leading zeros, prepends a sign byte on a
/// high top bit, encodes an all-zero scalar, and returns null (never throws) for
/// a wrong-length input.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keta_native/testing.dart';
// Reach into src directly: the encoder is internal to the verifier library and
// deliberately not exported, but it carries a strictness contract worth pinning.
import 'package:keta_oidc/src/verify/boringssl_verifier.dart';
import 'package:test/test.dart';

import 'crypto_support.dart';

void main() {
  group('round-trips real ECDSA signatures', () {
    test(
      'P-256 (ES256): raw→DER re-encodes to the canonical DER and verifies',
      () {
        final pair = EcKeyPair.generateP256();
        final message = Uint8List.fromList(utf8.encode('a message to sign'));
        final der = pair.signEcdsaSha256(message);

        final raw = derToRawRS(der, 32);
        expect(raw.length, 64);

        final reEncoded = joseEcdsaSignatureToDer(raw, 32)!;
        // Minimal-DER is canonical, so the re-encoding equals BoringSSL's own DER.
        expect(reEncoded, der);
        expect(pair.publicKey().verifyEcdsaSha256(message, reEncoded), isTrue);
      },
    );

    test('P-384 (ES384): raw→DER re-encodes and verifies', () {
      final pair = EcKeyPair.generateP384();
      final message = Uint8List.fromList(utf8.encode('another message'));
      final der = pair.signEcdsaSha384(message);

      final raw = derToRawRS(der, 48);
      expect(raw.length, 96);

      final reEncoded = joseEcdsaSignatureToDer(raw, 48)!;
      expect(reEncoded, der);
      expect(pair.publicKey().verifyEcdsaSha384(message, reEncoded), isTrue);
    });

    test(
      'many P-256 signatures round-trip (covers random leading-zero/high-bit r,s)',
      () {
        final pair = EcKeyPair.generateP256();
        for (var i = 0; i < 50; i++) {
          final message = Uint8List.fromList(utf8.encode('msg-$i'));
          final der = pair.signEcdsaSha256(message);
          final reEncoded = joseEcdsaSignatureToDer(derToRawRS(der, 32), 32)!;
          expect(reEncoded, der, reason: 'signature #$i did not round-trip');
        }
      },
    );
  });

  group('INTEGER encoding edge cases', () {
    test('strips leading zero bytes to the minimal magnitude', () {
      // r = 0x0000...0001 (leading zeros), s = 2.
      final raw = Uint8List(64);
      raw[31] = 0x01; // r's least-significant byte
      raw[63] = 0x02; // s's least-significant byte
      final der = joseEcdsaSignatureToDer(raw, 32)!;
      final (r, s) = encodedDerIntegers(der);
      expect(r, [0x01]);
      expect(s, [0x02]);
    });

    test('prepends 0x00 when the top bit of the magnitude is set', () {
      final raw = Uint8List(64);
      raw[0] = 0xFF; // r top byte -> high bit set
      raw[32] = 0x7F; // s top byte -> high bit clear
      final der = joseEcdsaSignatureToDer(raw, 32)!;
      final (r, s) = encodedDerIntegers(der);
      expect(r.first, 0x00); // sign byte prepended
      expect(r[1], 0xFF);
      expect(r.length, 33); // 32 magnitude + 1 sign byte
      expect(s.first, 0x7F); // no sign byte
      expect(s.length, 32);
    });

    test('an all-zero r and s still encodes (to INTEGER 0)', () {
      // Policy stays out of the encoder: a zero scalar is encoded and handed to
      // BoringSSL, which rejects it.
      final der = joseEcdsaSignatureToDer(Uint8List(64), 32)!;
      final (r, s) = encodedDerIntegers(der);
      expect(r, [0x00]);
      expect(s, [0x00]);
    });
  });

  group('wrong length returns null (never throws)', () {
    test('too long', () {
      expect(joseEcdsaSignatureToDer(Uint8List(96), 32), isNull); // 96 != 64
    });
    test('too short', () {
      expect(joseEcdsaSignatureToDer(Uint8List(63), 32), isNull);
    });
    test('empty', () {
      expect(joseEcdsaSignatureToDer(Uint8List(0), 32), isNull);
    });
    test('P-384 field size rejects a P-256-sized signature', () {
      expect(joseEcdsaSignatureToDer(Uint8List(64), 48), isNull); // 64 != 96
    });
  });
}
