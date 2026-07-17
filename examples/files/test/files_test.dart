import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/routes.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

Future<Env> bootTestEnv() async {
  final db = SqliteDb.memory();
  await applyMigrations(db, directory: 'migrations');
  return Env(db, StdoutLog(flushInterval: Duration.zero));
}

/// Mirrors lib/auth.dart's demo tokens. The app is secure by default.
const admin = {'authorization': 'Bearer t-admin'};

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
}
