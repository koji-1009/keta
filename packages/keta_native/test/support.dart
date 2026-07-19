/// Shared helpers for the keta_native test suite: hex/base64url decoding and
/// the JOSE-raw (`r || s`) to DER ECDSA-signature conversion the RFC 7515 A.3
/// vector needs (keta_native verifies DER; the raw<->DER bridge is the
/// caller's job, so the test does it here).
library;

import 'dart:convert';
import 'dart:typed_data';

Uint8List hex(String value) {
  final clean = value.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List b64url(String value) {
  final pad = (4 - value.length % 4) % 4;
  return base64Url.decode(value + '=' * pad);
}

Uint8List bytesOf(List<int> ints) => Uint8List.fromList(ints);

Uint8List asciiBytes(String value) => Uint8List.fromList(ascii.encode(value));

/// Encodes a fixed-width JOSE ECDSA signature (`r || s`, each half the field
/// width) as a DER `SEQUENCE { INTEGER r, INTEGER s }`.
Uint8List rawEcdsaSignatureToDer(Uint8List raw) {
  final half = raw.length ~/ 2;
  final r = _derInteger(raw.sublist(0, half));
  final s = _derInteger(raw.sublist(half));
  final body = <int>[...r, ...s];
  return Uint8List.fromList([0x30, ..._derLength(body.length), ...body]);
}

List<int> _derInteger(Uint8List value) {
  var start = 0;
  while (start < value.length - 1 && value[start] == 0) {
    start++;
  }
  var content = value.sublist(start);
  // DER INTEGER is signed: a leading bit set means prepend 0x00 to keep it
  // positive.
  if (content[0] & 0x80 != 0) {
    content = Uint8List.fromList([0, ...content]);
  }
  return [0x02, ..._derLength(content.length), ...content];
}

List<int> _derLength(int length) {
  if (length < 128) {
    return [length];
  }
  final bytes = <int>[];
  var remaining = length;
  while (remaining > 0) {
    bytes.insert(0, remaining & 0xff);
    remaining >>= 8;
  }
  return [0x80 | bytes.length, ...bytes];
}
