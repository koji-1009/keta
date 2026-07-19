library;

import 'dart:convert';
import 'dart:typed_data';

import 'algorithm.dart';
import 'base64url.dart';
import 'rejection.dart';

/// The decoded JOSE header of a JWS (RFC 7515 §4) — the parameters keta_oidc
/// reads, plus the [raw] header for the rest.
final class JoseHeader {
  const JoseHeader._({
    required this.algorithm,
    required this.kid,
    required this.type,
    required this.raw,
  });

  /// The signature algorithm (`alg`). Always a value in keta_oidc's allowlist:
  /// a header whose `alg` is `none`, an `HS*`, a `PS*`, or unrecognised never
  /// produces a [JoseHeader] — [Jws.parse] rejects it as [JwtMalformed] first.
  final JwsAlgorithm algorithm;

  /// The key id (`kid`), or `null`. The JWKS wave matches this against the keys
  /// it holds to resolve the verification key.
  final String? kid;

  /// The media type (`typ`), or `null`. Surfaced, not enforced: RFC 9068's
  /// `at+jwt` typing is a policy a later wave can add; this layer does not
  /// presume it.
  final String? type;

  /// The full decoded header object.
  final Map<String, Object?> raw;
}

/// A parsed JWS in compact serialization (RFC 7515 §3.1) — the three
/// dot-separated base64url segments of a signed JWT, decoded into a header, a
/// raw claims payload, the exact bytes that were signed, and the signature.
///
/// [parse] does **structural** work only: it decodes the compact form and
/// enforces that it *is* a well-formed JWS with an allowed algorithm. It does
/// not verify the signature and does not judge the claims (expiry, issuer,
/// audience) — those need a key and the caller's expectations, and are the
/// validator's job. Splitting it this way is what lets the caller read the
/// header's `kid` to resolve a key *before* verifying, which is the exact order
/// JWKS-based verification requires.
final class Jws {
  const Jws._({
    required this.header,
    required this.payload,
    required this.signingInput,
    required this.signature,
  });

  /// Parses a compact-serialization JWS from [token].
  ///
  /// Enforces, each failure as [JwtMalformed]:
  ///
  /// * exactly three `.`-separated segments (a JWS, not a 5-segment JWE);
  /// * each segment is strict RFC 7515 base64url (no padding, URL alphabet only)
  ///   — see [decodeBase64Url];
  /// * the header and payload each decode to a JSON **object**;
  /// * the header carries a string `alg` that is in keta_oidc's allowlist (so
  ///   `none`/`HS*`/`PS*`/unknown are rejected here, before any key is touched);
  /// * the header carries **no** `crit` parameter (RFC 7515 §4.1.11) — keta_oidc
  ///   implements no critical extension, so any `crit` marks processing this
  ///   server cannot honor and the token MUST be rejected.
  ///
  /// Parsing is **structural only**: it does not type the claims. The payload is
  /// required to be a JSON object, but whether its registered claims are
  /// well-typed (`exp` a number, `aud` a string-or-array, …) is checked by
  /// [JwtClaims], which the validator applies — [payload] is left as the raw
  /// decoded map. The signature segment is decoded to raw bytes but not verified.
  static Jws parse(String token) {
    // Exactly three segments. Splitting and counting (rather than a regexp)
    // also rejects a JWE's five segments and any stray dot.
    final segments = token.split('.');
    if (segments.length != 3) {
      throw JwtMalformed(
        'a compact JWS has exactly three "."-separated segments, found '
        '${segments.length}',
      );
    }
    final headerSeg = segments[0];
    final payloadSeg = segments[1];
    final signatureSeg = segments[2];

    final header = _decodeJsonObject(headerSeg, 'header');

    final algRaw = header['alg'];
    if (algRaw is! String) {
      throw const JwtMalformed('JOSE header has no string "alg"');
    }
    final algorithm = JwsAlgorithm.fromJose(algRaw);
    if (algorithm == null) {
      // The security-critical rejection: none / HS* / PS* / unknown never make
      // it past here. Naming the value makes the "HMAC confusion class is dead"
      // outcome legible in logs.
      throw JwtMalformed(
        'JOSE header "alg" "$algRaw" is not an accepted algorithm — keta_oidc '
        'accepts only RS256/RS384/RS512/ES256/ES384 (asymmetric only; "none", '
        'any HS*, and any PS* are rejected)',
      );
    }

    // RFC 7515 §4.1.11: `crit` lists header parameters the recipient MUST
    // understand and process. keta_oidc implements no critical extension, so any
    // `crit` names processing it cannot honor — its mere presence makes the JWS
    // invalid. Reject on presence alone; validating crit's internal shape (a
    // non-empty array of non-standard names) is unnecessary when every value is
    // a rejection anyway. Without this, a legitimately-signed token that
    // *demands* critical processing (e.g. an issuer-marked token-binding
    // extension) would be silently accepted as a plain bearer token, dropping a
    // constraint the issuer intended.
    if (header.containsKey('crit')) {
      throw const JwtMalformed(
        'the JOSE header marks extension(s) critical ("crit") that this server '
        'does not implement',
      );
    }

    final kid = _optionalString(header, 'kid');
    final typ = _optionalString(header, 'typ');

    final payload = _decodeJsonObject(payloadSeg, 'payload');

    // The signing input is the ASCII of "<header>.<payload>" exactly as it
    // appeared — the bytes the verifier must hash. Rebuild it from the original
    // segments (never re-encode the decoded JSON: re-encoding would change the
    // bytes and break verification).
    final signingInput = ascii.encode('$headerSeg.$payloadSeg');
    final signature = decodeBase64Url(signatureSeg, 'signature');

    return Jws._(
      header: JoseHeader._(
        algorithm: algorithm,
        kid: kid,
        type: typ,
        raw: header,
      ),
      payload: payload,
      signingInput: signingInput,
      signature: signature,
    );
  }

  /// The decoded JOSE header.
  final JoseHeader header;

  /// The decoded claims payload, raw. Registered claims are typed by [JwtClaims]
  /// (which the validator applies); this map is the whole payload.
  final Map<String, Object?> payload;

  /// The ASCII bytes of `"<header>.<payload>"` — exactly what the signature is
  /// computed over, handed unchanged to the [SignatureVerifier].
  final Uint8List signingInput;

  /// The raw signature bytes, decoded from the third segment. For `ES*` this is
  /// the JOSE `r ‖ s` form (see [SignatureVerifier]).
  final Uint8List signature;

  static Map<String, Object?> _decodeJsonObject(String segment, String what) {
    final bytes = decodeBase64Url(segment, what);
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException catch (e) {
      throw JwtMalformed('the $what is not valid UTF-8: ${e.message}');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw JwtMalformed('the $what is not valid JSON: ${e.message}');
    }
    if (json is! Map<String, Object?>) {
      throw JwtMalformed('the $what is not a JSON object');
    }
    return json;
  }

  static String? _optionalString(Map<String, Object?> header, String key) {
    final v = header[key];
    if (v == null) return null;
    if (v is! String) {
      throw JwtMalformed('JOSE header "$key" must be a string');
    }
    return v;
  }
}
