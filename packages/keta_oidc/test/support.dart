/// Test support: a recording stub [SignatureVerifier] and hand-encoding helpers
/// that build compact JWS strings from raw JSON segments, so the tests exercise
/// real base64url/JSON parsing rather than a mock of it.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keta_oidc/keta_oidc.dart';

/// A [SignatureVerifier] that records every call and returns a configured
/// result — no real crypto. The recorded [signingInput] lets a test assert that
/// the validator handed the verifier the exact bytes it was supposed to.
class StubVerifier implements SignatureVerifier {
  StubVerifier({this.result = true});

  /// The value every [verify] call returns.
  bool result;

  /// Every call, in order.
  final List<VerifyCall> calls = [];

  @override
  bool verify({
    required Jwk key,
    required JwsAlgorithm algorithm,
    required Uint8List signingInput,
    required Uint8List signature,
  }) {
    calls.add(
      VerifyCall(
        key: key,
        algorithm: algorithm,
        signingInput: signingInput,
        signature: signature,
      ),
    );
    return result;
  }
}

/// One recorded call to [StubVerifier.verify].
class VerifyCall {
  VerifyCall({
    required this.key,
    required this.algorithm,
    required this.signingInput,
    required this.signature,
  });

  final Jwk key;
  final JwsAlgorithm algorithm;
  final Uint8List signingInput;
  final Uint8List signature;
}

/// Encodes [bytes] as unpadded base64url — the JOSE segment encoding.
String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

/// Encodes a JSON [value] as an unpadded base64url segment.
String b64uJson(Object? value) => b64u(utf8.encode(jsonEncode(value)));

/// Builds a compact JWS string from a [header] object, a [payload] object, and
/// a raw [signature] byte string (default: three bytes, since the stub verifier
/// ignores its content).
String compactJws({
  required Map<String, Object?> header,
  required Map<String, Object?> payload,
  List<int> signature = const [1, 2, 3],
}) => '${b64uJson(header)}.${b64uJson(payload)}.${b64u(signature)}';

/// Builds a compact JWS whose payload segment is the **raw JSON text**
/// [payloadJson] (not re-encoded from a Map), so a test can smuggle a JSON
/// literal a Dart `Map` + `jsonEncode` could not produce — e.g. `1e400`, which
/// decodes to `Infinity`.
String compactJwsRawPayload({
  required Map<String, Object?> header,
  required String payloadJson,
  List<int> signature = const [1, 2, 3],
}) =>
    '${b64uJson(header)}.${b64u(utf8.encode(payloadJson))}.${b64u(signature)}';

/// Seconds-since-epoch for [t], as a JSON NumericDate.
int epochSeconds(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000;

/// An RSA JWK object (as decoded JSON) for use with `RS*` tokens. Component
/// bytes are placeholder base64url — the stub verifier never inspects them.
Map<String, Object?> rsaJwkJson({String? kid, String? alg}) => {
  'kty': 'RSA',
  'n': b64u(List<int>.filled(32, 7)),
  'e': b64u(const [1, 0, 1]),
  'kid': ?kid,
  'alg': ?alg,
};

/// An EC JWK object (as decoded JSON) for use with `ES*` tokens.
Map<String, Object?> ecJwkJson({
  String crv = 'P-256',
  String? kid,
  String? alg,
}) => {
  'kty': 'EC',
  'crv': crv,
  'x': b64u(List<int>.filled(32, 3)),
  'y': b64u(List<int>.filled(32, 4)),
  'kid': ?kid,
  'alg': ?alg,
};

/// A JWKS document (as a JSON string) wrapping [keys].
String jwksJson(List<Map<String, Object?>> keys) => jsonEncode({'keys': keys});

/// A [JoseHeader] with the given [kid] (and [alg]), obtained by parsing a
/// minimal token — [JoseHeader] has no public constructor, so this is how a
/// test names the header a JwksSource resolves against.
JoseHeader headerWith({String? kid, String alg = 'RS256'}) => Jws.parse(
  compactJws(header: {'alg': alg, 'kid': ?kid}, payload: <String, Object?>{}),
).header;
