/// A repeated-verify sanity loop: thousands of alternating valid/invalid
/// verifications must return stable results with no growth in the BoringSSL
/// error queue (a rejection would otherwise leave an error stacked, and a later
/// call could observe it). Also a coarse guard against per-call native leaks.
library;

import 'package:keta_native/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('5000 alternating RSA + EC verifications stay stable', () {
    final rsa = RsaKeyPair.generate();
    final rsaPub = rsa.publicKey();
    final ec = EcKeyPair.generateP256();
    final ecPub = ec.publicKey();

    final message = asciiBytes('repeated verification stress');
    final rsaSig = rsa.signPkcs1Sha256(message);
    final ecSig = ec.signEcdsaSha256(message);
    final badMessage = asciiBytes('a different message entirely');

    for (var i = 0; i < 5000; i++) {
      // Valid paths stay valid; invalid paths stay invalid — even immediately
      // after a rejection drained the error queue.
      expect(rsaPub.verifyPkcs1Sha256(message, rsaSig), isTrue);
      expect(rsaPub.verifyPkcs1Sha256(badMessage, rsaSig), isFalse);
      expect(ecPub.verifyEcdsaSha256(message, ecSig), isTrue);
      expect(ecPub.verifyEcdsaSha256(badMessage, ecSig), isFalse);
    }
  });
}
