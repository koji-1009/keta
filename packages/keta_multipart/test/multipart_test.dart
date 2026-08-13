/// `parts()`'s multipart/form-data contract: field/file yielding, boundary
/// and content-type validation, Content-Disposition parsing, size/count
/// limits, and out-of-order/partial-consumption safety against `package:mime`.
library;

import 'dart:async';
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

  group('content-type validation', () {
    test('a non-multipart request is a BadRequest', () {
      expect(
        parts(ctx(utf8.encode('x'), contentType: 'application/json')).toList(),
        throwsA(isA<BadRequest>()),
      );
    });

    test(
      'a content-type that merely shares the multipart/form-data prefix is a '
      'BadRequest, not accepted',
      () {
        // A `startsWith` gate would let a wholly distinct media type through.
        // The media type is now parsed and compared for equality instead.
        expect(
          parts(
            ctx(
              utf8.encode('x'),
              contentType: 'multipart/form-data-x; boundary=B',
            ),
          ).toList(),
          throwsA(isA<BadRequest>()),
        );
      },
    );
  });

  group('size and count limits', () {
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

    test('Part.stream enforces maxPartBytes', () {
      // The unbuffered path used to bypass the per-part cap entirely — a
      // second pin alongside the buffered `.bytes()` case above, since the
      // two go through different code paths.
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

    test(
      'a malformed disposition header yields no parameters, not a crash',
      () {
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
      },
    );

    test('name and filename are memoized: repeated reads return identical '
        'values off the same parse', () async {
      final raw = body('B', [
        ('Content-Disposition: form-data; name="f"; filename="a.txt"', 'x'),
      ]);
      await for (final p in parts(ctx(raw))) {
        // Read each accessor more than once; a memoized parse must still
        // agree with itself on every call, not just the first.
        expect(p.name, 'f');
        expect(p.name, 'f');
        expect(p.filename, 'a.txt');
        expect(p.filename, 'a.txt');
        expect(p.name, 'f');
      }
    });

    test('a malformed disposition header keeps degrading to null on every '
        'repeated read, not just the first', () async {
      // Pins the memoized failure case specifically: caching must store
      // "parsed and failed" distinctly from "not yet parsed", or a later
      // read could re-attempt the parse (harmless here, but not what
      // memoization promises) or misbehave in some other way.
      final raw = body('B', [
        ('Content-Disposition: form-data; name="unterminated', 'x'),
      ]);
      await for (final p in parts(ctx(raw))) {
        expect(p.name, isNull);
        expect(p.filename, isNull);
        expect(p.name, isNull);
        expect(p.filename, isNull);
      }
    });

    test(
      'a duplicated parameter is last-wins (current HeaderValue behavior)',
      () async {
        // Documented, not newly introduced: `HeaderValue.parse`'s parameters
        // map is filled by inserting each parameter as it is parsed, so a
        // name repeated in the header simply overwrites the earlier value.
        final raw = body('B', [
          ('Content-Disposition: form-data; name="first"; name="second"', 'x'),
        ]);
        final names = <String?>[];
        await for (final p in parts(ctx(raw))) {
          names.add(p.name);
        }
        expect(names, ['second']);
      },
    );
  });

  group('boundary parsing', () {
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
        parts(ctx(utf8.encode('x'), contentType: 'multipart/form-data'))
            .toList(),
        throwsA(isA<BadRequest>()),
      );
    });

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
          ctx(utf8.encode('x'), contentType: 'multipart/form-data; boundary='),
        ).toList(),
        throwsA(isA<BadRequest>()),
      );
    });
  });

  group('out-of-order / partial consumption', () {
    test(
      'skipping a part does not hang and the next is read in order',
      () async {
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
      },
    );

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

    test('a part claimed via .stream but never listened does not hang the '
        'request — the next part still arrives', () async {
      // `.stream` sets the single-read guard synchronously but returns a
      // lazy stream; stashing it away without ever listening used to leave
      // the underlying MIME transformer waiting forever for a subscriber
      // that never comes, since a skipped-but-unclaimed part is drained
      // but a claimed one was not. Draining now happens either way.
      final raw = body('B', [
        ('Content-Disposition: form-data; name="grabbed"', 'x' * 50),
        ('Content-Disposition: form-data; name="keep"', 'ok'),
      ]);
      final stashed = <Stream<List<int>>>[];
      final seen = <String>[];
      await for (final p in parts(ctx(raw))) {
        if (p.name == 'grabbed') {
          stashed.add(p.stream); // claimed, deliberately never listened
          continue;
        }
        seen.add(await p.text());
      }
      expect(seen, ['ok']);
      expect(stashed, hasLength(1));
    });

    test('bytes in a claimed-but-unlistened stream still count toward '
        'maxTotalBytes', () {
      // Same scenario as above, but the grabbed part is large enough that
      // if draining it were skipped (because it was "claimed"), the total
      // would stay under the limit. Draining it anyway is what makes the
      // limit unavoidable.
      final raw = body('B', [
        ('Content-Disposition: form-data; name="grabbed"', 'x' * 100),
        ('Content-Disposition: form-data; name="keep"', 'ok'),
      ]);
      expect(() async {
        final stashed = <Stream<List<int>>>[];
        await for (final p in parts(
          ctx(raw),
          limits: const MultipartLimits(maxTotalBytes: 60),
        )) {
          if (p.name == 'grabbed') {
            stashed.add(p.stream);
            continue;
          }
          await p.text();
        }
      }(), throwsA(isA<PayloadTooLarge>()));
    });
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

    group(
      'a frame the parser rejects is a BadRequest, not an escaped error',
      () {
        // package:mime reports an unparseable frame by throwing SYNCHRONOUSLY
        // from the source subscription's onData, so the throw lands in the zone
        // that registered the callback rather than on the stream `parts()`
        // returns. Unguarded that zone is the root zone, where the throw is an
        // unhandled error that ends the isolate — one unauthenticated POST was
        // enough to take a server down, and neither `recover()` nor the
        // transport's defensive catch could see it. Each case below rides that
        // exact path, so a regression is a dead test process, not a red
        // assertion.
        final rejected = {
          'a space inside a header field name': '--B\r\nContent Disposition: form-data; name="a"\r\n\r\nv\r\n--B--\r\n',
          'a boundary terminated by something other than CRLF': '--B\tX\r\nContent-Disposition: form-data; name="a"\r\n\r\nv\r\n--B--\r\n',
          'a bare CR inside a header value': '--B\r\nContent-Disposition: form-data;\rname="a"\r\n\r\nv\r\n--B--\r\n',
          'an empty body': '',
          'a body with no boundary in it at all': 'not multipart at all',
        };
        for (final entry in rejected.entries) {
          test(entry.key, () {
            expect(
              parts(ctx(utf8.encode(entry.value))).toList(),
              throwsA(isA<BadRequest>()),
            );
          });
        }
      },
    );

    test('a body that stops arriving ends the read instead of hanging', () async {
      // A truncated upload produces NO event: the parser never advances and
      // never fails, and dart:io leaves the request body stalled rather than
      // erroring it, so an unguarded `await part.text()` waits forever and
      // holds its request slot. `c.aborted` — completed here by `abort()`, in
      // production by a disconnect, a `timeout()`, or a graceful shutdown — is
      // the only signal that arrives, so it must terminate both the part
      // stream and the body being read.
      final peerGone = Completer<void>();
      final c = testContext<Object?>(
        null,
        method: 'POST',
        headers: {'content-type': 'multipart/form-data; boundary=B'},
        // A part header and the start of its body, with no closing boundary.
        rawBody: utf8.encode(
          '--B\r\nContent-Disposition: form-data; name="a"\r\n\r\npar',
        ),
        closed: peerGone.future,
      );
      final reads = <Object>[];
      final loop = () async {
        await for (final p in parts(c)) {
          try {
            reads.add(await p.text());
          } on KetaException catch (e) {
            reads.add(e);
          }
        }
      }();
      // The read is outstanding; nothing has failed on its own.
      await Future<void>.delayed(Duration.zero);
      expect(reads, isEmpty);

      peerGone.complete();
      await expectLater(loop, throwsA(isA<BadRequest>()));
      expect(reads.single, isA<BadRequest>());
    });

    group('over a real socket', () {
      // This package had no wire-level test at all, and it is the one that
      // rides the deliberate `c.bodyStream()` escape (so `maxBodyBytes` does
      // not apply, and these limits are the only ones there are) while handing
      // framing to a third-party parser. Both of the defects below are
      // invisible to `testContext`: the parser's throw goes to the root zone
      // rather than to any future a test awaits, and a truncated upload
      // produces no event at all, only a peer that stops talking.
      late TestServer server;

      String upload(String body, {int? declaredLength}) =>
          'POST /u HTTP/1.1\r\n'
          'host: x\r\n'
          'content-type: multipart/form-data; boundary=B\r\n'
          'content-length: ${declaredLength ?? body.length}\r\n'
          '\r\n$body';

      setUp(() async {
        final app = App<Object?>()
          ..use(recover())
          ..post('/u', (c) async {
            final names = <String>[];
            await for (final p in parts(c)) {
              names.add('${p.name}=${await p.text()}');
            }
            return c.text(names.join(','));
          });
        server = await TestServer.start(app, null);
      });
      tearDown(() => server.close());

      test('a malformed part header answers 400 and leaves the server '
          'serving', () async {
        // Before the parser's throw was contained this did not return 400 — it
        // ended the process. Under `serve(isolates: n)` it took a worker per
        // request until it hit the one that ends everything. Unauthenticated,
        // one request, no body size needed.
        final first = await server.sendRaw(
          upload(
            '--B\r\nContent Disposition: form-data; name="a"\r\n\r\nv\r\n'
            '--B--\r\n',
          ),
        );
        expect(TestServer.statusOf(first), 400);

        // The point of the wire test: a live server answering afterwards is the
        // assertion. A dead one cannot fail this — it never replies at all.
        final second = await server.sendRaw(
          upload(
            '--B\r\nContent-Disposition: form-data; name="a"\r\n\r\nv\r\n'
            '--B--\r\n',
          ),
        );
        expect(TestServer.statusOf(second), 200);
      });

      test('a client that abandons a half-sent upload does not strand the '
          'request', () async {
        // Declares more than it sends, then half-closes: the peer is gone with
        // the body unfinished. dart:io neither errors nor closes the request
        // body here, so an unguarded read waits forever and holds its slot.
        const partial =
            '--B\r\nContent-Disposition: form-data; name="a"\r\n'
            '\r\npar';
        await server.sendRaw(
          upload(partial, declaredLength: partial.length + 500),
          halfCloseAfterWrite: true,
        );
        // The abandoned request answers nothing (the peer left), so the
        // observable is that the server is still healthy rather than pinned.
        final after = await server.sendRaw(
          upload(
            '--B\r\nContent-Disposition: form-data; name="a"\r\n\r\nok\r\n'
            '--B--\r\n',
          ),
        );
        expect(TestServer.statusOf(after), 200);
        expect(after, contains('a=ok'));
      });
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
