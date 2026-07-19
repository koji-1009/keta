library;

import 'dart:convert';
import 'dart:typed_data';

import 'rejection.dart';

/// Decodes one **strict RFC 7515 §2** base64url segment, throwing
/// [JwtMalformed] on anything that is not exactly that.
///
/// JOSE base64url encoding is the URL- and filename-safe alphabet with **the
/// padding removed**. This decoder holds that line precisely, because a lax
/// decoder is a source of token-smuggling ambiguity: two different byte strings
/// that decode from inputs a strict verifier would reject can let a signature
/// computed over one framing be replayed under another.
///
/// Rejected, each as [JwtMalformed]:
///
/// * any `=` — padding is not part of the encoding here;
/// * any character outside `A–Z a–z 0–9 - _` — in particular the standard
///   base64 `+` and `/`, and any whitespace or newline;
/// * a length that cannot be a whole number of encoded bytes (`length % 4 == 1`).
///
/// [what] names the segment (`'header'`, `'payload'`, `'signature'`) so the
/// error says which one was bad.
Uint8List decodeBase64Url(String segment, String what) {
  // Validate the alphabet up front. Walking the code units once lets the error
  // point at the offending character and keeps padding ('=') and the standard
  // base64 alphabet ('+'/'/') out — accepting either would make this something
  // other than RFC 7515 base64url.
  for (var i = 0; i < segment.length; i++) {
    final c = segment.codeUnitAt(i);
    final ok =
        (c >= 0x41 && c <= 0x5A) || // A-Z
        (c >= 0x61 && c <= 0x7A) || // a-z
        (c >= 0x30 && c <= 0x39) || // 0-9
        c == 0x2D || // -
        c == 0x5F; // _
    if (!ok) {
      throw JwtMalformed(
        'the $what segment is not RFC 7515 base64url: illegal character '
        'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')} at index $i '
        '(padding and the standard base64 "+"/"/" alphabet are rejected)',
      );
    }
  }
  // A base64url segment has length 4k, 4k+2, or 4k+3; length 4k+1 can never be a
  // whole number of decoded bytes. Reject it before decoding for a precise error
  // rather than a generic FormatException.
  if (segment.length % 4 == 1) {
    throw JwtMalformed(
      'the $what segment is not valid base64url: its length '
      '(${segment.length}) is not a whole number of encoded bytes',
    );
  }
  // The alphabet is already verified; re-pad to a multiple of 4 so the SDK
  // decoder — which requires canonical padding — can do the byte conversion.
  final padded = switch (segment.length % 4) {
    2 => '$segment==',
    3 => '$segment=',
    _ => segment,
  };
  try {
    return base64Url.decode(padded);
  } on FormatException catch (e) {
    // Reachable, and a real strictness property: the alphabet and length checks
    // pass a segment whose final base64 char sets bits with no home in a whole
    // byte (non-canonical trailing bits — e.g. "Ab" would decode the same byte
    // as "AQ" under a lax decoder, but its low 4 bits are non-zero). The SDK
    // decoder rejects that ("Invalid encoding before padding"); catching it here
    // turns encoding malleability into a JwtMalformed rather than letting a
    // FormatException escape.
    throw JwtMalformed(
      'the $what segment is not valid base64url: ${e.message}',
    );
  }
}
