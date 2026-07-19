/// Known-answer tests for the digest and HMAC surface: SHA-2 against the
/// classic NIST "abc" vectors, HMAC against RFC 4231 (including the
/// short-key, long-data, and larger-than-block-size-key cases).
library;

import 'package:keta_native/keta_native.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('SHA-2 (NIST "abc" vectors)', () {
    final abc = asciiBytes('abc');
    test('sha256', () {
      expect(
        toHex(sha256(abc)),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
    test('sha384', () {
      expect(
        toHex(sha384(abc)),
        'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed'
        '8086072ba1e7cc2358baeca134c825a7',
      );
    });
    test('sha512', () {
      expect(
        toHex(sha512(abc)),
        'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
        '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
      );
    });
    test('sha256 of the empty input', () {
      expect(
        toHex(sha256(bytesOf(const []))),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  group('HMAC (RFC 4231)', () {
    // (label, key, data, sha256, sha384, sha512)
    final cases = <(String, List<int>, List<int>, String, String, String)>[
      (
        'case 1 — 20-byte key',
        hex('0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b'),
        asciiBytes('Hi There'),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
        'afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59c'
            'faea9ea9076ede7f4af152e8b2fa9cb6',
        '87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde'
            'daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854',
      ),
      (
        'case 2 — key shorter than the output ("Jefe")',
        asciiBytes('Jefe'),
        asciiBytes('what do ya want for nothing?'),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
        'af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e'
            '8e2240ca5e69e2c78b3239ecfab21649',
        '164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554'
            '9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737',
      ),
      (
        'case 3 — combined length over the block size',
        hex('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        hex('dd' * 50),
        '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe',
        '88062608d3e6ad8a0aa2ace014c8a86f0aa635d947ac9febe83ef4e55966144b'
            '2a5ab39dc13814b94e3ab6e101a34f27',
        'fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39'
            'bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb',
      ),
      (
        'case 6 — key larger than the block size (131 bytes, hashed first)',
        hex('aa' * 131),
        asciiBytes('Test Using Larger Than Block-Size Key - Hash Key First'),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
        '4ece084485813e9088d2c63a041bc5b44f9ef1012a2b588f3cd11f05033ac4c6'
            '0c2ef6ab4030fe8296248df163f44952',
        '80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352'
            '6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598',
      ),
      (
        'case 7 — key and data both larger than the block size',
        hex('aa' * 131),
        asciiBytes(
          'This is a test using a larger than block-size key and a larger '
          'than block-size data. The key needs to be hashed before being '
          'used by the HMAC algorithm.',
        ),
        '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2',
        '6617178e941f020d351e2f254e8fd32c602420feb0b8fb9adccebb82461e99c5'
            'a678cc31e799176d3860e6110c46523e',
        'e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944'
            'b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58',
      ),
    ];

    for (final (label, key, data, s256, s384, s512) in cases) {
      test(label, () {
        expect(toHex(hmacSha256(bytesOf(key), bytesOf(data))), s256);
        expect(toHex(hmacSha384(bytesOf(key), bytesOf(data))), s384);
        expect(toHex(hmacSha512(bytesOf(key), bytesOf(data))), s512);
      });
    }
  });
}
