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

  test('exceeding maxParts is a BadRequest, not PayloadTooLarge', () {
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
    }(), throwsA(isA<BadRequest>()));
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

  group('Content-Disposition parsing', () {
    test('an escaped quote inside a quoted filename is preserved', () async {
      // On the wire: filename="a\"b"  (a, escaped quote, b). The old regex
      // truncated at the backslash; a proper quoted-string parser keeps it.
      final raw = body('B', [
        ('Content-Disposition: form-data; name="f"; filename="a\\"b"', 'x'),
      ]);
      final names = <(String?, String?)>[];
      await for (final p in parts(ctx(raw))) {
        names.add((p.name, p.filename));
      }
      expect(names, [('f', 'a"b')]);
    });

    test('an unquoted parameter value (legal token) is read', () async {
      // Non-browser clients may send bare tokens; the old regex required quotes
      // and silently returned null.
      final raw = body('B', [
        ('Content-Disposition: form-data; name=greeting', 'hi'),
      ]);
      final names = <String?>[];
      await for (final p in parts(ctx(raw))) {
        names.add(p.name);
      }
      expect(names, ['greeting']);
    });

    test('parameter names are matched case-insensitively', () async {
      // The old regex matched `name`/`filename` case-sensitively while the
      // boundary parse was case-insensitive — an inconsistency clients can trip.
      final raw = body('B', [
        (
          'Content-Disposition: form-data; Name="greeting"; FileName="a.txt"',
          'hi',
        ),
      ]);
      final got = <(String?, String?)>[];
      await for (final p in parts(ctx(raw))) {
        got.add((p.name, p.filename));
      }
      expect(got, [('greeting', 'a.txt')]);
    });

    test('an RFC 5987 filename*= extended value is not treated as filename', () {
      // Documented as unsupported: it surfaces under the key `filename*`, so a
      // percent-encoded name reads as absent rather than being mis-decoded.
      final raw = body('B', [
        (
          'Content-Disposition: form-data; name="f"; '
              "filename*=UTF-8''%e2%82%ac.txt",
          'x',
        ),
      ]);
      expect(() async {
        await for (final p in parts(ctx(raw))) {
          expect(p.name, 'f');
          expect(p.filename, isNull);
        }
      }(), completes);
    });

    test('a malformed disposition header yields no parameters, not a crash', () {
      // An unterminated quote makes HeaderValue.parse throw; a synchronous
      // getter must degrade to null rather than tear the stream down.
      final raw = body('B', [
        ('Content-Disposition: form-data; name="unterminated', 'x'),
      ]);
      expect(() async {
        await for (final p in parts(ctx(raw))) {
          expect(p.name, isNull);
        }
      }(), completes);
    });
  });

  group('boundary parsing', () {
    test('a quoted boundary containing a semicolon is honored', () async {
      final raw = body('a;b', [
        ('Content-Disposition: form-data; name="x"', 'val'),
      ]);
      final got = <(String?, String)>[];
      await for (final p in parts(
        ctx(raw, contentType: 'multipart/form-data; boundary="a;b"'),
      )) {
        got.add((p.name, await p.text()));
      }
      expect(got, [('x', 'val')]);
    });

    test('an empty boundary parameter is a BadRequest', () {
      expect(
        parts(
          ctx(
            utf8.encode('x'),
            contentType: 'multipart/form-data; boundary=',
          ),
        ).toList(),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  group('out-of-order / partial consumption', () {
    test('skipping a part does not hang and the next is read in order', () async {
      final raw = body('B', [
        ('Content-Disposition: form-data; name="skip"', 'x' * 100),
        ('Content-Disposition: form-data; name="keep"', 'ok'),
      ]);
      final seen = <String>[];
      await for (final p in parts(ctx(raw))) {
        if (p.name == 'skip') continue; // never touch the body
        seen.add(await p.text());
      }
      expect(seen, ['ok']);
    });

    test('bytes in a skipped part still count toward maxTotalBytes', () {
      // The skipped 100-byte part is drained through the total meter, so a
      // consumer cannot dodge maxTotalBytes by refusing to read a part. The
      // 'keep' part alone (~50 bytes framed) fits under 60; the whole body does
      // not.
      final raw = body('B', [
        ('Content-Disposition: form-data; name="skip"', 'x' * 100),
        ('Content-Disposition: form-data; name="keep"', 'ok'),
      ]);
      expect(() async {
        await for (final p in parts(
          ctx(raw),
          limits: const MultipartLimits(maxTotalBytes: 60),
        )) {
          if (p.name == 'skip') continue;
          await p.text();
        }
      }(), throwsA(isA<PayloadTooLarge>()));
    });

    test('reading a part body twice is a StateError', () {
      final raw = body('B', [
        ('Content-Disposition: form-data; name="a"', 'hi'),
      ]);
      expect(() async {
        await for (final p in parts(ctx(raw))) {
          await p.bytes();
          await p.bytes(); // second read of a single-subscription stream
        }
      }(), throwsA(isA<StateError>()));
    });
  });

  test('Part.stream enforces maxPartBytes', () {
    // The unbuffered path used to bypass the per-part cap entirely.
    final raw = body('B', [
      ('Content-Disposition: form-data; name="big"', 'x' * 100),
    ]);
    expect(() async {
      await for (final p in parts(
        ctx(raw),
        limits: const MultipartLimits(maxPartBytes: 10),
      )) {
        await for (final _ in p.stream) {}
      }
    }(), throwsA(isA<PayloadTooLarge>()));
  });

  group('package:mime integration edges', () {
    test('preamble and epilogue junk are ignored', () async {
      // RFC 2046 permits a preamble before the first boundary and an epilogue
      // after the closing one; both must be discarded.
      final raw = utf8.encode(
        'this preamble precedes the first boundary\r\n'
        '--B\r\nContent-Disposition: form-data; name="a"\r\n\r\nhello\r\n'
        '--B\r\nContent-Disposition: form-data; name="b"\r\n\r\nworld\r\n'
        '--B--\r\n'
        'and this epilogue trails the closing boundary\r\n',
      );
      final got = <(String?, String)>[];
      await for (final p in parts(ctx(raw))) {
        got.add((p.name, await p.text()));
      }
      expect(got, [('a', 'hello'), ('b', 'world')]);
    });

    test('boundary-like bytes inside a body are preserved verbatim', () async {
      // Near-misses that never complete a `\r\n--B` delimiter: inline dashes,
      // lone `--`, and a different boundary token must round-trip untouched.
      const content =
          'prefix --B inline dashes\r\n'
          '-- lone dashes then text\r\n'
          '--A is a different boundary\r\n'
          'trailing token B and --B-ish';
      final raw = body('B', [
        ('Content-Disposition: form-data; name="a"', content),
      ]);
      final got = <String>[];
      await for (final p in parts(ctx(raw))) {
        got.add(await p.text());
      }
      expect(got, [content]);
    });
  });
}
