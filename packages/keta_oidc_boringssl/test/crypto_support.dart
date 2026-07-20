/// Test support for the real-crypto (BoringSSL) suite: helpers that build
/// signed JWS tokens with `package:keta_native` testing keys and that decode DER
/// ECDSA signatures.
///
/// This is a minimal, standalone duplicate of keta_oidc's own
/// `test/crypto_support.dart` (plus the handful of `test/support.dart`
/// helpers it relies on): keta_oidc's test-support files are not part of its
/// public API, so `boringssl_verifier_test.dart` and `der_encoder_test.dart`
/// — moved here because they reach into `BoringSslVerifier`'s `src/` directly
/// — cannot import them across the package boundary. Only the functions those
/// two tests actually call are reproduced.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keta_native/testing.dart';

/// Encodes [bytes] as unpadded base64url — the JOSE segment encoding.
String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Encodes a JSON [value] as an unpadded base64url segment.
String b64uJson(Object? value) => b64u(utf8.encode(jsonEncode(value)));

/// Seconds-since-epoch for [t], as a JSON NumericDate.
int epochSeconds(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000;

/// A JWKS document (as a JSON string) wrapping [keys].
String jwksJson(List<Map<String, Object?>> keys) => jsonEncode({'keys': keys});

/// Builds a compact JWS whose signature is produced by [sign] over the real
/// `"<header>.<payload>"` signing input — so the token verifies under real
/// crypto. [sign] returns the JOSE signature bytes (raw PKCS#1 for `RS*`, raw
/// `r ‖ s` for `ES*`).
String signedToken({
  required String alg,
  required String kid,
  required Uint8List Function(Uint8List signingInput) sign,
  Map<String, Object?> claims = const {},
}) {
  final headerSeg = b64uJson({'alg': alg, 'kid': kid});
  final payloadSeg = b64uJson({
    'iss': 'https://issuer',
    'aud': 'api://resource',
    'sub': 'user-1',
    'exp': epochSeconds(DateTime.now().add(const Duration(hours: 1))),
    ...claims,
  });
  final signingInput = ascii.encode('$headerSeg.$payloadSeg');
  return '$headerSeg.$payloadSeg.${b64u(sign(signingInput))}';
}

/// A JWKS entry (decoded JSON) for an RSA [pair].
Map<String, Object?> rsaJwkOf(
  RsaKeyPair pair, {
  required String kid,
  required String alg,
}) => {
  'kty': 'RSA',
  'kid': kid,
  'alg': alg,
  'n': b64u(pair.modulus),
  'e': b64u(pair.exponent),
};

/// A JWKS entry (decoded JSON) for an EC [pair] on [crv].
Map<String, Object?> ecJwkOf(
  EcKeyPair pair, {
  required String kid,
  required String crv,
  required String alg,
}) => {
  'kty': 'EC',
  'crv': crv,
  'kid': kid,
  'alg': alg,
  'x': b64u(pair.x),
  'y': b64u(pair.y),
};

/// Decodes a DER ECDSA signature (`SEQUENCE { r, s }`) into the raw fixed-width
/// `r ‖ s` of `2 * fieldSize` bytes that JOSE carries.
Uint8List derToRawRS(Uint8List der, int fieldSize) {
  final (r, s) = _twoIntegers(der);
  final out = Uint8List(2 * fieldSize);
  final rMag = _stripSign(r);
  final sMag = _stripSign(s);
  out.setRange(fieldSize - rMag.length, fieldSize, rMag);
  out.setRange(2 * fieldSize - sMag.length, 2 * fieldSize, sMag);
  return out;
}

/// The two INTEGER contents of a DER `SEQUENCE { r, s }`, exactly as encoded
/// (including any `0x00` sign byte) — for asserting the encoder's output shape.
(Uint8List, Uint8List) encodedDerIntegers(Uint8List der) => _twoIntegers(der);

(Uint8List, Uint8List) _twoIntegers(Uint8List der) {
  var pos = 0;
  int readByte() => der[pos++];
  int readLen() {
    final first = readByte();
    if (first < 0x80) return first;
    final n = first & 0x7f;
    var len = 0;
    for (var k = 0; k < n; k++) {
      len = (len << 8) | readByte();
    }
    return len;
  }

  if (readByte() != 0x30) {
    throw const FormatException('expected a DER SEQUENCE');
  }
  readLen(); // sequence content length (not needed)
  Uint8List readInteger() {
    if (readByte() != 0x02) {
      throw const FormatException('expected a DER INTEGER');
    }
    final len = readLen();
    final bytes = Uint8List.fromList(
      Uint8List.sublistView(der, pos, pos + len),
    );
    pos += len;
    return bytes;
  }

  return (readInteger(), readInteger());
}

Uint8List _stripSign(Uint8List integer) {
  var start = 0;
  while (start < integer.length - 1 && integer[start] == 0) {
    start++;
  }
  return Uint8List.sublistView(integer, start);
}
