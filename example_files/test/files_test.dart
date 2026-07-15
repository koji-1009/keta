import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/routes.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

Future<Env> bootTestEnv() async {
  final db = SqliteDb.memory();
  await applyMigrations(db, directory: 'migrations');
  return Env(db, StdoutLog(flushInterval: Duration.zero));
}

/// Mirrors lib/auth.dart's demo tokens. The app is secure by default, so every
/// request that is not explicitly public carries credentials.
const admin = {'authorization': 'Bearer t-admin'};

void main() {
  group('file-convention wiring', () {
    test('the committed manifest has every route file registered', () {
      final source = File('lib/routes.dart').readAsStringSync();
      final files = discoverRouteFiles('lib/routes');
      expect(
        files.map((f) => f.prefix),
        containsAll(['health', 'session', 'uploads', 'users']),
      );
      expect(unregistered(source, files), isEmpty);
    });

    test('syncManifest is idempotent on the synced manifest', () {
      final source = File('lib/routes.dart').readAsStringSync();
      final files = discoverRouteFiles('lib/routes');
      expect(syncManifest(source, files), source);
    });
  });

  test(
    'OpenAPI output covers the same route set as the register-based example',
    () {
      final paths =
          (OpenApi.fromRoutes(buildApp().routes).toJson()['paths'] as Map).keys;
      expect(
        paths,
        containsAll([
          '/health',
          '/users',
          '/users/{id}',
          '/users/{uid}/tags/{index}',
          '/uploads',
          '/metrics',
          '/whoami',
          '/admin/ping',
        ]),
      );
    },
  );

  test('the document says exactly what the gate does', () {
    // The register-based example has this test; without it here, deleting
    // `security: apiDefaults` from buildOpenApi would leave this suite green
    // while tool/openapi.dart published a contract calling every endpoint
    // public that the runtime still 401s.
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

  test('the security declarations reach the file-convention app too', () async {
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
    expect((await client.get('/users/1/tags/1', headers: admin)).json(), {
      'tag': 'y',
    });

    final list = (await client.get('/users', headers: admin)).json()! as Map;
    expect(list['total'], 1);
    expect(list['users'], hasLength(1));

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
