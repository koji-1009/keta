/// Pins [Jws.parse]'s structural contract: three-segment framing, strict
/// RFC 7515 base64url (no padding, URL alphabet only), header/payload must be
/// JSON objects, `alg` required, and the algorithm allowlist enforced at parse
/// time — `none`, `HS*`, and unknown algorithms never resolve to a value.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:keta_oidc/keta_oidc.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('segment framing', () {
    test('a token with two segments is malformed', () {
      expect(
        () => Jws.parse('${b64uJson({'alg': 'RS256'})}.${b64uJson({})}'),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('a JWE-shaped five-segment token is malformed', () {
      expect(
        () => Jws.parse('a.b.c.d.e'),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            contains('three'),
          ),
        ),
      );
    });

    test('an empty string is malformed', () {
      expect(() => Jws.parse(''), throwsA(isA<JwtMalformed>()));
    });
  });

  group('base64url strictness', () {
    test('a padded segment is rejected', () {
      // Build a valid token, then pad the header segment with "=".
      final valid = compactJws(header: {'alg': 'RS256'}, payload: {});
      final parts = valid.split('.');
      final padded = '${parts[0]}==.${parts[1]}.${parts[2]}';
      expect(
        () => Jws.parse(padded),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            contains('base64url'),
          ),
        ),
      );
    });

    test('a non-URL-alphabet character ("+") is rejected', () {
      // '+' and '/' belong to standard base64, not base64url.
      final valid = compactJws(header: {'alg': 'RS256'}, payload: {});
      final parts = valid.split('.');
      final bad = '${parts[0]}+.${parts[1]}.${parts[2]}';
      expect(
        () => Jws.parse(bad),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            contains('illegal character'),
          ),
        ),
      );
    });

    test('a "/" (standard base64) character is rejected', () {
      final valid = compactJws(header: {'alg': 'RS256'}, payload: {});
      final parts = valid.split('.');
      final bad = '${parts[0]}.${parts[1]}/.${parts[2]}';
      expect(() => Jws.parse(bad), throwsA(isA<JwtMalformed>()));
    });

    test('a segment with non-canonical trailing bits is rejected', () {
      // "Ab" and "AQ" both pass the alphabet+length checks and both "intend"
      // the byte 0x01, but "Ab" leaves non-zero low bits with no home in a whole
      // byte — the encoding-malleability the strict decoder forbids. "AQ"
      // (canonical) decodes; "Ab" must be rejected.
      final header = b64uJson({'alg': 'RS256'});
      final payload = b64uJson(<String, Object?>{});
      expect(() => Jws.parse('$header.$payload.AQ'), returnsNormally);
      expect(
        () => Jws.parse('$header.$payload.Ab'),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  group('header shape', () {
    test('a header that is a JSON array (not object) is malformed', () {
      final token =
          '${b64u(utf8.encode('[1,2,3]'))}.${b64uJson({})}.${b64u(const [1])}';
      expect(
        () => Jws.parse(token),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            contains('object'),
          ),
        ),
      );
    });

    test('a header that is not JSON is malformed', () {
      final token =
          '${b64u(utf8.encode('not json'))}.${b64uJson({})}.${b64u(const [1])}';
      expect(() => Jws.parse(token), throwsA(isA<JwtMalformed>()));
    });

    test('a payload that is not a JSON object is malformed', () {
      final token =
          '${b64uJson({'alg': 'RS256'})}.${b64u(utf8.encode('42'))}.${b64u(const [1])}';
      expect(() => Jws.parse(token), throwsA(isA<JwtMalformed>()));
    });

    test('a header with no "alg" is malformed', () {
      expect(
        () => Jws.parse(compactJws(header: {'kid': 'k1'}, payload: {})),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            contains('alg'),
          ),
        ),
      );
    });

    test('a header whose "alg" is not a string is malformed', () {
      expect(
        () => Jws.parse(compactJws(header: {'alg': 42}, payload: {})),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  group('algorithm allowlist at parse time', () {
    test('alg: none is rejected as malformed', () {
      expect(
        () => Jws.parse(compactJws(header: {'alg': 'none'}, payload: {})),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            allOf(contains('none'), contains('asymmetric')),
          ),
        ),
      );
    });

    test('alg: HS256 is rejected — the HMAC confusion class is dead', () {
      // A token asking for HMAC verification never parses. There is no HS256
      // value to select, so no key can be pressed into service as an HMAC secret.
      expect(
        () => Jws.parse(compactJws(header: {'alg': 'HS256'}, payload: {})),
        throwsA(
          isA<JwtMalformed>().having(
            (e) => e.message,
            'message',
            allOf(contains('HS256'), contains('HS*')),
          ),
        ),
      );
    });

    test('an unknown alg string is rejected as malformed', () {
      expect(
        () => Jws.parse(compactJws(header: {'alg': 'RS999'}, payload: {})),
        throwsA(isA<JwtMalformed>()),
      );
    });

    test('PS256 (unsupported) is rejected as malformed', () {
      expect(
        () => Jws.parse(compactJws(header: {'alg': 'PS256'}, payload: {})),
        throwsA(isA<JwtMalformed>()),
      );
    });
  });

  group('a well-formed token', () {
    test('parses into header, payload, signing input, and signature', () {
      final header = {'alg': 'RS256', 'kid': 'k1', 'typ': 'JWT'};
      final payload = {'iss': 'https://issuer', 'sub': 'user-1'};
      final token = compactJws(
        header: header,
        payload: payload,
        signature: const [9, 8, 7],
      );

      final jws = Jws.parse(token);

      expect(jws.header.algorithm, JwsAlgorithm.rs256);
      expect(jws.header.kid, 'k1');
      expect(jws.header.type, 'JWT');
      expect(jws.payload['iss'], 'https://issuer');
      expect(jws.payload['sub'], 'user-1');
      expect(jws.signature, Uint8List.fromList(const [9, 8, 7]));

      // The signing input is the ASCII of "<header>.<payload>", the first two
      // segments exactly as they appeared on the wire.
      final parts = token.split('.');
      expect(jws.signingInput, ascii.encode('${parts[0]}.${parts[1]}'));
    });
  });
}
