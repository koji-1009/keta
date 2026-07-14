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

void main() {
  group('file-convention wiring', () {
    test('the committed manifest has every route file registered', () {
      final source = File('lib/routes.dart').readAsStringSync();
      final files = discoverRouteFiles('lib/routes');
      expect(
        files.map((f) => f.prefix),
        containsAll(['health', 'uploads', 'users']),
      );
      expect(unregistered(source, files), isEmpty);
    });

    test('syncManifest is idempotent on the synced manifest', () {
      final source = File('lib/routes.dart').readAsStringSync();
      final files = discoverRouteFiles('lib/routes');
      expect(syncManifest(source, files), source);
    });
  });

  test('OpenAPI output covers the same route set as the register-based example', () {
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
      ]),
    );
  });

  test('serves the full CRUD surface end-to-end', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    final created = await client.post(
      '/users',
      json: {
        'id': '1',
        'name': 'Ada',
        'role': 'admin',
        'tags': ['x', 'y'],
      },
    );
    expect(created.status, 201);
    expect(created.headers['location'], '/users/1');
    expect((await client.get('/users/1')).json(), {
      'id': '1',
      'name': 'Ada',
      'role': 'admin',
      'tags': ['x', 'y'],
    });
    expect((await client.get('/users/1/tags/1')).json(), {'tag': 'y'});

    final list = (await client.get('/users')).json()! as Map;
    expect(list['total'], 1);
    expect(list['users'], hasLength(1));

    expect(
      (await client.put(
        '/users/1',
        json: {'id': '1', 'name': 'Ada B', 'role': 'member', 'tags': <String>[]},
      )).status,
      200,
    );
    expect((await client.delete('/users/1')).status, 204);
    expect((await client.get('/users/1')).status, 404);
    expect((await client.post('/users', json: {'id': '2'})).status, 400);
  });
}
