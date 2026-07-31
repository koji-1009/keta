/// Pins the claims this package's README makes, including the two it warns
/// about.
///
/// The README is the only description of keta_static a user gets, and this
/// package shipped without one — so the first version of it says what the code
/// does today, including the parts that are inconvenient. A warning nobody
/// tests is a warning that goes stale silently, which is worse than no warning:
/// a reader who checks it and finds it fixed learns nothing, and a reader who
/// trusts it after it changes is misled.
@TestOn('vm')
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_static/keta_static.dart';
import 'package:test/test.dart';

App<Object?> appWith(Map<String, String> assets) => App<Object?>()
  ..use(recover())
  ..use(
    // `ofText` is the constructor the README's table names first, so the
    // documented ergonomic path is the one under test.
    staticFiles<Object?>(
      prefix: '/assets',
      source: MemoryAssets.ofText(assets),
    ),
  )
  ..get('/assets/dynamic', (c) => c.text('a route under the same prefix'))
  ..get('/elsewhere', (c) => c.text('unrelated'));

void main() {
  group('a mount, not a wildcard route', () {
    test('a miss falls through to the application', () async {
      final client = TestClient(appWith({'a.txt': 'A'}), null);
      // The README's central claim: a route lives under the same prefix.
      expect((await client.get('/assets/dynamic')).status, 200);
      // And a miss is the application's 404, not one this mount invents.
      expect((await client.get('/assets/nope.txt')).status, 404);
    });

    test('only GET and HEAD are answered; other verbs pass through', () async {
      final client = TestClient(appWith({'a.txt': 'A'}), null);
      expect((await client.get('/assets/a.txt')).status, 200);
      // POST is not this mount's business, so it reaches the 405/404 the
      // application would have produced anyway.
      expect((await client.post('/assets/a.txt')).status, isNot(200));
    });
  });

  group('what it answers with', () {
    test(
      'a hit carries ETag, Accept-Ranges and the default Cache-Control',
      () async {
        final client = TestClient(appWith({'a.txt': 'A'}), null);
        final res = await client.get('/assets/a.txt');
        expect(res.status, 200);
        expect(res.headers['etag'], isNotNull);
        expect(res.headers['accept-ranges'], 'bytes');
        // The README states this default explicitly.
        expect(res.headers['cache-control'], contains('max-age=3600'));
        expect(res.headers['cache-control'], contains('public'));
      },
    );

    test('a matching If-None-Match is a 304 with no content-type', () async {
      final client = TestClient(appWith({'a.txt': 'A'}), null);
      final first = await client.get('/assets/a.txt');
      final res = await client.get(
        '/assets/a.txt',
        headers: {'if-none-match': first.headers['etag']!},
      );
      expect(res.status, 304);
      expect(res.headers.containsKey('content-type'), isFalse);
    });

    test('a byte range is a 206 with Content-Range', () async {
      final client = TestClient(appWith({'a.txt': 'ABCDEFGHIJ'}), null);
      final res = await client.get(
        '/assets/a.txt',
        headers: {'range': 'bytes=2-4'},
      );
      expect(res.status, 206);
      expect(res.headers['content-range'], 'bytes 2-4/10');
      expect(res.text(), 'CDE');
    });

    test('an unsatisfiable range is a 416', () async {
      final client = TestClient(appWith({'a.txt': 'ABC'}), null);
      final res = await client.get(
        '/assets/a.txt',
        headers: {'range': 'bytes=99-200'},
      );
      expect(res.status, 416);
    });

    test('the conditional check precedes the range check', () async {
      // RFC 9110 §13.1.3, and the README says so: a current cached copy wins
      // over a range request for the representation it already has.
      final client = TestClient(appWith({'a.txt': 'ABCDEFGHIJ'}), null);
      final first = await client.get('/assets/a.txt');
      final res = await client.get(
        '/assets/a.txt',
        headers: {
          'if-none-match': first.headers['etag']!,
          'range': 'bytes=2-4',
        },
      );
      expect(res.status, 304);
    });
  });

  group('path handling, exactly as the README states it', () {
    test('a traversal attempt never reaches the mount', () async {
      // Uri.path is already percent-decoded and dot-segment-normalized, so
      // this resolves to /secret and does not match the prefix at all.
      final client = TestClient(appWith({'a.txt': 'A', 'secret': 'S'}), null);
      final res = await client.get('/assets/%2e%2e/secret');
      expect(res.status, 404);
      expect(res.text(), isNot(contains('S')));
    });

    test('WARNED: dotfiles are served', () async {
      // The README tells a user not to point DirectoryAssets at a directory
      // that also holds secrets or a repository. This is why.
      final client = TestClient(appWith({'.env': 'SECRET_KEY=hunter2'}), null);
      final res = await client.get('/assets/.env');
      expect(res.status, 200);
      expect(res.text(), contains('hunter2'));
    }, skip: null);

    test('WARNED: a percent-encoded name does not resolve', () async {
      // The asset exists under its decoded name and is still unreachable.
      final client = TestClient(appWith({'a b.js': 'JS'}), null);
      expect((await client.get('/assets/a%20b.js')).status, 404);
    });
  });
}
