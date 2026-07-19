/// Malformed key material is rejected at construction with [ArgumentError] —
/// never a crash, never a silently-accepted bad key.
library;

import 'package:keta_native/keta_native.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('RSA', () {
    test('empty modulus throws ArgumentError', () {
      expect(
        () => RsaPublicKey.fromComponents(bytesOf(const []), b64url('AQAB')),
        throwsArgumentError,
      );
    });

    test('zero exponent throws ArgumentError', () {
      expect(
        () => RsaPublicKey.fromComponents(
          bytesOf(List.filled(256, 0xff)),
          bytesOf(const [0, 0, 0]),
        ),
        throwsArgumentError,
      );
    });

    test('empty exponent throws ArgumentError', () {
      expect(
        () => RsaPublicKey.fromComponents(
          bytesOf(List.filled(256, 0xff)),
          bytesOf(const []),
        ),
        throwsArgumentError,
      );
    });
  });

  group('EC', () {
    // A valid-length P-256 coordinate to pair against a bad one.
    final good32 = bytesOf(List.filled(32, 0x01));

    test('x of the wrong length throws ArgumentError', () {
      expect(
        () => EcPublicKey.p256(bytesOf(List.filled(31, 0x01)), good32),
        throwsArgumentError,
      );
    });

    test('y of the wrong length throws ArgumentError', () {
      expect(
        () => EcPublicKey.p256(good32, bytesOf(List.filled(33, 0x01))),
        throwsArgumentError,
      );
    });

    test('P-384 rejects 32-byte (P-256-sized) coordinates', () {
      expect(() => EcPublicKey.p384(good32, good32), throwsArgumentError);
    });

    test('correctly-sized but off-curve point throws ArgumentError', () {
      // 32 bytes each, correct length, but almost certainly not on the curve.
      expect(
        () => EcPublicKey.p256(
          bytesOf(List.filled(32, 0x02)),
          bytesOf(List.filled(32, 0x03)),
        ),
        throwsArgumentError,
      );
    });
  });
}
