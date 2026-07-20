/// The static mount: what it answers, what it passes through, and what it
/// refuses. Every case runs the real pipeline through TestClient, so the
/// mount's placement in the chain is exercised rather than assumed.
library;

import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_static/keta_static.dart';
import 'package:test/test.dart';

final _assets = MemoryAssets.ofText({
  'index.html': '<!doctype html><title>home</title>',
  'app.js': 'console.log(1);',
  'sub/deep.txt': '0123456789',
});

App<void> buildApp({
  String prefix = '/assets',
  AssetSource? source,
  CacheControl? cache,
}) {
  final app = App<void>()
    ..use(recover())
    ..use(
      staticFiles(
        prefix: prefix,
        source: source ?? _assets,
        cache:
            cache ??
            const CacheControl(isPublic: true, maxAge: Duration(hours: 1)),
      ),
    );
  app.get('/assets/dynamic', (c) => c.text('route wins where no asset exists'));
  app.get('/elsewhere', (c) => c.text('untouched'));
  return app;
}

void main() {
  group('serving', () {
    test(
      'answers an asset with its media type, validator and cache policy',
      () async {
        final res = await TestClient(buildApp(), null).get('/assets/app.js');
        expect(res.status, 200);
        expect(res.headers['content-type'], 'text/javascript; charset=utf-8');
        expect(res.headers['etag'], matches(r'^"[0-9a-f]{16}"$'));
        expect(res.headers['accept-ranges'], 'bytes');
        expect(res.headers['cache-control'], 'public, max-age=3600');
        expect(res.text(), 'console.log(1);');
      },
    );

    test(
      'serves the index file for the mount root and for a directory path',
      () async {
        final client = TestClient(buildApp(), null);
        expect((await client.get('/assets')).text(), contains('home'));
        expect((await client.get('/assets/')).text(), contains('home'));
      },
    );

    test('serves a nested path', () async {
      final res = await TestClient(
        buildApp(),
        null,
      ).get('/assets/sub/deep.txt');
      expect(res.status, 200);
      expect(res.text(), '0123456789');
    });

    test(
      'an unknown extension is octet-stream, never a guessed text type',
      () async {
        final app = buildApp(
          source: MemoryAssets.ofText({'thing.weird': 'x'}, indexFile: null),
        );
        final res = await TestClient(app, null).get('/assets/thing.weird');
        expect(res.headers['content-type'], 'application/octet-stream');
      },
    );
  });

  group('passing through', () {
    test('a path outside the mount is untouched', () async {
      final res = await TestClient(buildApp(), null).get('/elsewhere');
      expect(res.text(), 'untouched');
    });

    test(
      'a path under the mount with no asset falls through to the route',
      () async {
        final res = await TestClient(buildApp(), null).get('/assets/dynamic');
        expect(res.status, 200);
        expect(res.text(), 'route wins where no asset exists');
      },
    );

    test('a miss with no route behind it is an ordinary 404, not one this '
        'mount invented', () async {
      final res = await TestClient(buildApp(), null).get('/assets/nothing.png');
      expect(res.status, 404);
    });

    test('a non-GET/HEAD method is not this mount\'s business', () async {
      final res = await TestClient(buildApp(), null).post('/assets/app.js');
      expect(res.status, isNot(200));
    });

    test('a prefix that is a string prefix but not a path prefix does not '
        'match', () async {
      final app = App<void>()
        ..use(staticFiles(prefix: '/assets', source: _assets));
      app.get('/assetsx', (c) => c.text('different route'));
      expect(
        (await TestClient(app, null).get('/assetsx')).text(),
        'different route',
      );
    });
  });

  group('conditional requests', () {
    test('a matching If-None-Match is 304 with no content-type', () async {
      final client = TestClient(buildApp(), null);
      final first = await client.get('/assets/app.js');
      final tag = first.headers['etag']!;
      final second = await client.get(
        '/assets/app.js',
        headers: {'if-none-match': tag},
      );
      expect(second.status, 304);
      expect(second.headers['content-type'], isNull);
      expect(second.headers['etag'], tag);
    });

    test('* matches whatever exists', () async {
      final res = await TestClient(
        buildApp(),
        null,
      ).get('/assets/app.js', headers: {'if-none-match': '*'});
      expect(res.status, 304);
    });

    test('a stale validator serves the representation again', () async {
      final res = await TestClient(
        buildApp(),
        null,
      ).get('/assets/app.js', headers: {'if-none-match': '"0000000000000000"'});
      expect(res.status, 200);
    });
  });

  group('ranges', () {
    Future<TestResponse> ranged(String value) => TestClient(
      buildApp(),
      null,
    ).get('/assets/sub/deep.txt', headers: {'range': value});

    test('a byte range is 206 with Content-Range', () async {
      final res = await ranged('bytes=2-5');
      expect(res.status, 206);
      expect(res.headers['content-range'], 'bytes 2-5/10');
      expect(res.text(), '2345');
    });

    test('an open-ended and a suffix range', () async {
      expect((await ranged('bytes=7-')).text(), '789');
      expect((await ranged('bytes=-3')).text(), '789');
    });

    test(
      'an unsatisfiable range is 416 and says what would have been valid',
      () async {
        final res = await ranged('bytes=100-200');
        expect(res.status, 416);
        expect(res.headers['content-range'], 'bytes */10');
      },
    );

    test('a Range this server cannot parse is ignored — the whole '
        'representation, per RFC 9110', () async {
      final res = await ranged('items=2-5');
      expect(res.status, 200);
      expect(res.text(), '0123456789');
    });

    test('a conditional request wins over a range request', () async {
      final client = TestClient(buildApp(), null);
      final tag = (await client.get('/assets/sub/deep.txt')).headers['etag']!;
      final res = await client.get(
        '/assets/sub/deep.txt',
        headers: {'if-none-match': tag, 'range': 'bytes=0-1'},
      );
      expect(res.status, 304);
    });
  });

  group('traversal', () {
    test('a path escaping the mount is refused, decoded or not', () async {
      final client = TestClient(buildApp(), null);
      for (final path in [
        '/assets/../secret',
        '/assets/sub/../../secret',
        '/assets/%2e%2e/secret',
      ]) {
        final res = await client.get(path);
        expect(res.status, isNot(200), reason: path);
      }
    });

    test(
      'a dot segment never reaches the guard: Uri has already removed it',
      () async {
        // Worth pinning rather than assuming — the guard refuses `.` and `..`
        // outright, and this is the reason it almost never has to.
        final res = await TestClient(buildApp(), null).get('/assets/./app.js');
        expect(res.status, 200);
        expect(res.text(), 'console.log(1);');
      },
    );

    test(
      'a directory source refuses a file resolved outside its root',
      () async {
        final root = Directory.systemTemp.createTempSync('keta_static_test');
        addTearDown(() => root.deleteSync(recursive: true));
        File('${root.path}/ok.txt').writeAsStringSync('inside');
        final outside = File('${root.path}/../keta_static_outside.txt')
          ..writeAsStringSync('outside');
        addTearDown(outside.deleteSync);

        final app = buildApp(source: DirectoryAssets(root));
        final client = TestClient(app, null);
        expect((await client.get('/assets/ok.txt')).text(), 'inside');
        expect(
          (await client.get('/assets/keta_static_outside.txt')).status,
          404,
        );
      },
    );
  });

  test('the mount prefix normalizes: bare, leading and trailing slashes all '
      'mount the same place', () async {
    for (final prefix in ['assets', '/assets', '/assets/']) {
      final res = await TestClient(
        buildApp(prefix: prefix),
        null,
      ).get('/assets/app.js');
      expect(res.status, 200, reason: prefix);
    }
  });

  test('mounted at the root, it still lets routes through', () async {
    final app = App<void>()..use(staticFiles(prefix: '/', source: _assets));
    app.get('/api', (c) => c.text('api'));
    final client = TestClient(app, null);
    expect((await client.get('/app.js')).text(), 'console.log(1);');
    expect((await client.get('/api')).text(), 'api');
    expect((await client.get('/')).text(), contains('home'));
  });

  test(
    'a binary asset is served as its own bytes, not through a text codec',
    () async {
      final bytes = List<int>.generate(256, (i) => i);
      final app = buildApp(
        source: MemoryAssets.ofBytes({'raw.bin': bytes}, indexFile: null),
      );
      // 0..255 is not valid UTF-8, and TestClient decodes a body as UTF-8 —
      // so a socket-free test cannot carry these bytes back at all. What it
      // CAN assert is the length the server computed over them, which
      // Content-Range reports without decoding anything: 256 means the asset
      // was measured as bytes and never round-tripped through a text codec.
      final ranged = await TestClient(
        app,
        null,
      ).get('/assets/raw.bin', headers: {'range': 'bytes=0-0'});
      expect(ranged.status, 206);
      expect(ranged.headers['content-type'], 'application/octet-stream');
      expect(ranged.headers['content-range'], 'bytes 0-0/256');
    },
  );
}
