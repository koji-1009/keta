import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_multipart/keta_multipart.dart';
import 'package:test/test.dart';

List<int> body(String boundary, List<(String, String)> parts) {
  final sb = StringBuffer();
  for (final (headers, content) in parts) {
    sb.write('--$boundary\r\n$headers\r\n\r\n$content\r\n');
  }
  sb.write('--$boundary--\r\n');
  return utf8.encode(sb.toString());
}

Context<Object?> ctx(
  List<int> raw, {
  String contentType = 'multipart/form-data; boundary=B',
}) => testContext<Object?>(
  null,
  method: 'POST',
  headers: {'content-type': contentType},
  rawBody: raw,
);

void main() {
  test('yields fields and files with name / filename / text', () async {
    final raw = body('B', [
      ('Content-Disposition: form-data; name="greeting"', 'hello'),
      (
        'Content-Disposition: form-data; name="upload"; filename="a.txt"\r\n'
            'Content-Type: text/plain',
        'file-body',
      ),
    ]);
    final collected = <(String?, String?, String)>[];
    await for (final p in parts(ctx(raw))) {
      collected.add((p.name, p.filename, await p.text()));
    }
    expect(collected, [
      ('greeting', null, 'hello'),
      ('upload', 'a.txt', 'file-body'),
    ]);
  });

  test('a non-multipart request is a BadRequest', () {
    expect(
      parts(ctx(utf8.encode('x'), contentType: 'application/json')).toList(),
      throwsA(isA<BadRequest>()),
    );
  });

  test('a case-insensitive Boundary= parameter name is honored', () async {
    final raw = body('B', [
      ('Content-Disposition: form-data; name="greeting"', 'hello'),
    ]);
    final collected = <(String?, String)>[];
    await for (final p in parts(
      ctx(raw, contentType: 'multipart/form-data; Boundary=B'),
    )) {
      collected.add((p.name, await p.text()));
    }
    expect(collected, [('greeting', 'hello')]);
  });

  test('a missing boundary is a BadRequest', () {
    expect(
      parts(ctx(utf8.encode('x'), contentType: 'multipart/form-data')).toList(),
      throwsA(isA<BadRequest>()),
    );
  });

  test('a part over maxPartBytes is PayloadTooLarge', () {
    final raw = body('B', [
      ('Content-Disposition: form-data; name="big"', 'x' * 100),
    ]);
    expect(() async {
      await for (final p in parts(
        ctx(raw),
        limits: const MultipartLimits(maxPartBytes: 10),
      )) {
        await p.bytes();
      }
    }(), throwsA(isA<PayloadTooLarge>()));
  });

  test('exceeding maxParts is PayloadTooLarge', () {
    final raw = body('B', [
      ('Content-Disposition: form-data; name="a"', '1'),
      ('Content-Disposition: form-data; name="b"', '2'),
    ]);
    expect(() async {
      await for (final p in parts(
        ctx(raw),
        limits: const MultipartLimits(maxParts: 1),
      )) {
        await p.bytes();
      }
    }(), throwsA(isA<PayloadTooLarge>()));
  });

  test('exceeding maxTotalBytes is PayloadTooLarge', () {
    final raw = body('B', [
      ('Content-Disposition: form-data; name="a"', 'x' * 100),
    ]);
    expect(() async {
      await for (final p in parts(
        ctx(raw),
        limits: const MultipartLimits(maxTotalBytes: 20),
      )) {
        await p.bytes();
      }
    }(), throwsA(isA<PayloadTooLarge>()));
  });
}
