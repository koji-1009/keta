/// keta_files' own charter — the tree IS the route table, and everything
/// string-routing cannot express needs the file to say it — grouped
/// alongside the CRUD surface, security, and OpenAPI-conformance suites that
/// mirror ../register's file-routed equivalents so the two examples can be
/// diffed test-by-test.
library;

import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/routes.dart';
// Prefixed: this is the only place the file-routed example needs the
// register-based one, and only to diff the two OpenAPI documents below — its
// Env, principal, etc. must never leak into the rest of this suite.
import 'package:keta_register_example/app.dart' as register;
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

/// The routes half of [discover]; the cases below only diff the file→URL
/// mapping against the manifest.
List<RouteFile> discoverRouteFiles(String routesDir) =>
    discover(routesDir).routes;

Future<Env> bootTestEnv() async {
  final db = SqliteDb.memory();
  await applyMigrations(db, directory: 'migrations');
  return Env(db, StdoutLog(flushInterval: Duration.zero));
}

/// Mirrors lib/auth.dart's demo tokens. The app is secure by default.
const admin = {'authorization': 'Bearer t-admin'};
const user = {'authorization': 'Bearer t-user'};

void main() {
  group('the tree is the route table', () {
    test('a file location denotes its URL, and nothing else does', () {
      final files = discoverRouteFiles('lib/routes');
      expect(
        {for (final f in files) f.importPath: f.url},
        {
          'routes/admin/ping.dart': '/admin/ping',
          'routes/health.dart': '/health',
          'routes/metrics.dart': '/metrics',
          'routes/uploads.dart': '/uploads',
          'routes/users.dart': '/users',
          'routes/users/_id.dart': '/users/:id',
          'routes/users/_uid/tags/_index.dart': '/users/:uid/tags/:index',
          'routes/whoami.dart': '/whoami',
        },
      );
      // The claim under all of it: no route file writes its own URL. The moment
      // one does, the tree has stopped being the route table and is only
      // decorating one.
      for (final f in files) {
        expect(
          File('lib/${f.importPath}').readAsStringSync(),
          isNot(contains("'${f.url}'")),
          reason: '${f.importPath} names its own URL; its location should',
        );
      }
    });

    test('what a file serves is the type\'s to state, not the tree\'s', () {
      // The generator knows only where a file is. What it answers is its
      // `exported`'s type, checked by the compiler at the one line that binds
      // it — so discovery has nothing to guess and nothing to get quietly
      // wrong. This is the whole reason keta_files needs no analyzer.
      final app = buildApp();
      Set<String> methodsAt(String template) => {
        for (final r in app.routes)
          if (r.template == template) r.method,
      };
      expect(methodsAt('/users'), {'GET', 'POST'});
      expect(methodsAt('/users/:id'), {'GET', 'PUT', 'DELETE'});
      expect(methodsAt('/health'), {'GET'});
    });

    test('the committed manifest is exactly what the tree generates', () {
      // Not "is a superset", not "mentions": syncing must be a no-op, or the
      // URLs served are not the URLs on disk.
      final source = File('lib/routes.dart').readAsStringSync();
      final files = discoverRouteFiles('lib/routes');
      expect(syncManifest(source, files), source);
      expect(unregistered(source, files), isEmpty);
    });

    test('a file the manifest does not bind is caught, not silently 404', () {
      // Forgetting is otherwise invisible: the file compiles, the suite passes,
      // and the URL is simply not there.
      final files = discoverRouteFiles('lib/routes');
      final withoutOne = File('lib/routes.dart').readAsStringSync().replaceAll(
        "import 'routes/whoami.dart' as \$whoami;",
        '',
      );
      expect(unregistered(withoutOne, files).map((f) => f.url), ['/whoami']);
    });
  });

  group('what the tree cannot say, the file does', () {
    test('a capture is a string unless the file declares otherwise', () {
      final doc = buildOpenApi().toJson();
      Object? schemaOf(String path, String name) {
        final params =
            (((doc['paths'] as Map)[path] as Map)['get'] as Map)['parameters']
                as List;
        return (params.firstWhere((p) => (p as Map)['name'] == name)
            as Map)['schema'];
      }

      // routes/users/_id.dart declares no captures, so `id` is a string — the
      // same default every file-routing convention has.
      expect(schemaOf('/users/{id}', 'id'), {'type': 'string'});
      // routes/users/_uid/tags/_index.dart declares `{'index': integer}`. This
      // is the fidelity the string syntax cannot reach: `:index` has no
      // vocabulary for a type, so it could only ever have been a string.
      expect(schemaOf('/users/{uid}/tags/{index}', 'uid'), {'type': 'string'});
      expect(schemaOf('/users/{uid}/tags/{index}', 'index'), {
        'type': 'integer',
      });
    });

    test('a declared capture is enforced at the boundary', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      await client.post(
        '/users',
        headers: admin,
        json: {
          'id': '1',
          'name': 'Ada',
          'role': 'admin',
          'tags': ['x', 'y'],
        },
      );
      expect((await client.get('/users/1/tags/1', headers: admin)).json(), {
        'tag': 'y',
      });
      // `index` is an integer, so a non-integer is a 400 — decided by the
      // declaration, not by the handler remembering to parse defensively.
      expect(
        (await client.get('/users/1/tags/abc', headers: admin)).status,
        400,
      );
    });
  });

  group('openapi conformance', () {
    test('the document says exactly what the gate does', () {
      final doc = buildOpenApi().toJson();
      Map<String, Object?> op(String path) =>
          ((doc['paths'] as Map)[path] as Map)['get'] as Map<String, Object?>;

      expect(op('/health').containsKey('security'), isFalse);
      expect(op('/users')['security'], [
        {'bearer': <String>[]},
      ]);
      expect(op('/metrics')['security'], [
        {'apiKey': <String>[]},
      ]);
      expect(
        ((doc['components'] as Map)['securitySchemes'] as Map).keys,
        unorderedEquals(['bearer', 'apiKey']),
      );
    });

    test('the shared CRUD surface documents identically to ../register', () {
      // The two examples' OpenAPI documents are NOT identical as a whole:
      // ../register has since grown /users/by-role/:role (a custom Capture) and
      // /users/events (an SSE feed) that this file-routed tree does not mirror
      // — mirroring them would need an events bus and a custom SSE capture in
      // keta_files, which is its own piece of work, not a doc-wording fix. What
      // is still true, and worth asserting rather than just claiming in prose,
      // is that every route this tree *does* serve — the shared CRUD surface —
      // documents identically on both sides. Restricting ../register's document
      // to exactly this tree's path set and diffing turns "we didn't check"
      // into an assertion: a summary edited on one side, a schema changed on
      // the other, or a route silently dropped now fails here, loudly, instead
      // of rotting behind a claim nobody re-reads.
      final filesPaths = buildOpenApi().toJson()['paths']! as Map;
      final registerPaths = register.buildOpenApi().toJson()['paths']! as Map;
      expect(
        registerPaths.keys.toSet().containsAll(filesPaths.keys),
        isTrue,
        reason: 'every route this tree serves must also exist in ../register',
      );
      final sharedRegisterPaths = {
        for (final path in filesPaths.keys) path: registerPaths[path],
      };
      expect(sharedRegisterPaths, filesPaths);
    });
  });

  group('the security declarations are enforced, not decorative', () {
    test(
      'directory-scoped middleware guards /admin, not just the security gate',
      () async {
        // routes/admin/_middleware.dart's ScopedMiddleware<Env>([requireAdmin()])
        // now does what routes/admin/ping.dart used to inline: 401 says "who are
        // you" (the security gate, enforceSecurity), 403 says "not you" (the
        // admin-scope middleware) — the same split ../register makes with
        // app.group('/admin').use(requireAdmin()).
        final env = await bootTestEnv();
        addTearDown(env.close);
        final client = TestClient(buildApp(), env);
        expect((await client.get('/admin/ping', headers: admin)).status, 200);
        expect((await client.get('/admin/ping', headers: user)).status, 403);
        expect((await client.get('/admin/ping')).status, 401);
      },
    );

    test('the security declarations reach the file-routed app too', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      expect((await client.get('/health')).status, 200); // explicitly public
      expect((await client.get('/users')).status, 401); // inherits the default
      expect((await client.get('/whoami', headers: admin)).json(), {
        'id': 'ada',
        'admin': true,
      });
    });
  });

  group('the CRUD surface', () {
    test('PUT rejects a body id that disagrees with the path id', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);

      await client.post(
        '/users',
        headers: admin,
        json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
      );

      // The schema requires a body `id`; nothing checked it agreed with the path
      // one. Unchecked, this updated row 1 and echoed back id "2" — a silent
      // rename through a path that named a different row.
      final mismatch = await client.put(
        '/users/1',
        headers: admin,
        json: {'id': '2', 'name': 'Ada B', 'role': 'admin', 'tags': <String>[]},
      );
      expect(mismatch.status, 400);
      expect(
        (await client.get('/users/1', headers: admin)).json(),
        containsPair('name', 'Ada'),
      );

      final match = await client.put(
        '/users/1',
        headers: admin,
        json: {'id': '1', 'name': 'Ada B', 'role': 'admin', 'tags': <String>[]},
      );
      expect(match.status, 200);
      expect(match.json(), containsPair('name', 'Ada B'));
    });

    test('a zero-tag user 404s at any tag index, not ""', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);

      await client.post(
        '/users',
        headers: admin,
        json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
      );

      // The tags column is a comma-joined `''`, and `''.split(',')` is `['']`,
      // not `[]` — unguarded, index 0 answered `{"tag": ""}` instead of 404.
      expect((await client.get('/users/1/tags/0', headers: admin)).status, 404);
    });

    test('serves the full CRUD surface end-to-end', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);

      final created = await client.post(
        '/users',
        headers: admin,
        json: {
          'id': '1',
          'name': 'Ada',
          'role': 'admin',
          'tags': ['x', 'y'],
        },
      );
      expect(created.status, 201);
      expect(created.headers['location'], '/users/1');
      expect((await client.get('/users/1', headers: admin)).json(), {
        'id': '1',
        'name': 'Ada',
        'role': 'admin',
        'tags': ['x', 'y'],
      });

      final list = (await client.get('/users', headers: admin)).json()! as Map;
      expect(list['total'], 1);

      expect(
        (await client.put(
          '/users/1',
          headers: admin,
          json: {
            'id': '1',
            'name': 'Ada B',
            'role': 'member',
            'tags': <String>[],
          },
        )).status,
        200,
      );
      expect((await client.delete('/users/1', headers: admin)).status, 204);
      expect((await client.get('/users/1', headers: admin)).status, 404);
      expect(
        (await client.post('/users', headers: admin, json: {'id': '2'})).status,
        400,
      );
    });

    test(
      'pagination clamps bounds, pages with offset, and keeps ?role working',
      () async {
        final env = await bootTestEnv();
        addTearDown(env.close);
        final client = TestClient(buildApp(), env);
        // ids 1..3, ordered by id; roles let ?role be exercised alongside paging.
        for (final r in [('1', 'admin'), ('2', 'member'), ('3', 'member')]) {
          await client.post(
            '/users',
            headers: admin,
            json: {
              'id': r.$1,
              'name': 'U${r.$1}',
              'role': r.$2,
              'tags': <String>[],
            },
          );
        }
        Future<List<String>> page(String q) async {
          final body =
              (await client.get('/users$q', headers: admin)).json()! as Map;
          return [
            for (final u in body['items'] as List) (u as Map)['id'] as String,
          ];
        }

        final all = (await client.get('/users', headers: admin)).json()! as Map;
        expect(all['total'], 3);
        expect(await page(''), ['1', '2', '3']);
        // Offset windows the page; total stays the full count.
        expect(await page('?limit=2&offset=1'), ['2', '3']);
        // Out of range → empty page, total intact (not a 400).
        final over =
            (await client.get('/users?offset=99', headers: admin)).json()!
                as Map;
        expect(over['items'], isEmpty);
        expect(over['total'], 3);
        // Clamped bounds don't error.
        expect(await page('?limit=9999'), ['1', '2', '3']);
        expect(await page('?offset=-5'), ['1', '2', '3']);
        // ?role still filters, with its own total.
        final members =
            (await client.get('/users?role=member', headers: admin)).json()!
                as Map;
        expect(members['total'], 2);
        expect(await page('?role=member'), ['2', '3']);
      },
    );

    test('a comma in a tag is a 400 naming the CSV constraint', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      final bad = await client.post(
        '/users',
        headers: admin,
        json: {
          'id': '1',
          'name': 'Ada',
          'role': 'admin',
          'tags': ['a,b'],
        },
      );
      expect(bad.status, 400);
      expect((bad.json()! as Map)['error'], contains('comma'));
      // The write never happened — the boundary rejected before the insert.
      expect((await client.get('/users/1', headers: admin)).status, 404);
    });
  });

  test(
    'the per-buildApp metrics registry is scraped through the store',
    () async {
      // routes/metrics.dart reads the registry provideMetrics put in the request
      // store — the buildApp-scoped one otel records into. A broken wiring would
      // be a 500 here (c.get on an absent key), so a green scrape proves the
      // per-buildApp scoping actually reaches the file-routed handler.
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      await client.get('/health'); // record a request into the registry
      final scrape = await client.get(
        '/metrics',
        headers: const {'x-api-key': 'k-metrics'},
      );
      expect(scrape.status, 200);
      expect(scrape.text(), contains('keta_requests_total'));
    },
  );
}
