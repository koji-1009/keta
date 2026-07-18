/// Owns Context's request-body reading: the maxBodyBytes limit (413) and
/// invalid-JSON (400) errors staying sticky across re-reads, the empty/decoded
/// body and raw bytes caching, and the body stream being consumable only once.
library;

import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('request body', () {
    test(
      'exceeding maxBodyBytes is a 413, the exact limit is allowed',
      () async {
        final under = testContext(
          newEnv(),
          method: 'POST',
          rawBody: utf8.encode('12345678'),
          maxBodyBytes: 8,
        );
        expect((await under.bodyBytes()).length, 8);

        final over = testContext(
          newEnv(),
          method: 'POST',
          rawBody: utf8.encode('123456789'),
          maxBodyBytes: 8,
        );
        await expectLater(
          over.bodyBytes(),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 413)),
        );
        // A retry must re-throw the 413, not an opaque "stream already listened"
        // StateError (which would escape as a 500).
        await expectLater(
          over.bodyBytes(),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 413)),
        );
        await expectLater(
          over.body(),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 413)),
        );
      },
    );

    test('invalid JSON is a 400, and a retry still throws', () async {
      final c = testContext(newEnv(), rawBody: utf8.encode('{not json'));
      await expectLater(
        c.body(),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
      // Caching is success-only, so a second read re-throws rather than
      // returning a stale null.
      await expectLater(c.body(), throwsA(isA<KetaException>()));
    });

    test('an empty body decodes to null and is cached', () async {
      final c = testContext(newEnv());
      expect(await c.body(), isNull);
      expect(await c.body(), isNull);
    });

    test('the decoded body and raw bytes are cached across calls', () async {
      final c = testContext(newEnv(), jsonBody: {'a': 1});
      final first = await c.body();
      expect(identical(first, await c.body()), isTrue);
      final bytes = await c.bodyBytes();
      expect(identical(bytes, await c.bodyBytes()), isTrue);
    });

    test('the body stream can be consumed only once', () async {
      final c1 = testContext(newEnv(), jsonBody: {'a': 1});
      c1.bodyStream();
      expect(() => c1.bodyStream(), throwsStateError);
      await expectLater(c1.bodyBytes(), throwsStateError);

      // Reading bytes first lets bodyStream replay the cached bytes.
      final c2 = testContext(newEnv(), jsonBody: {'a': 1});
      final bytes = await c2.bodyBytes();
      expect(await c2.bodyStream().expand((x) => x).toList(), bytes);
    });
  });
}
