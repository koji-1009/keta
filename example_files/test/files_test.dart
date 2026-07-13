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
      expect(files.map((f) => f.prefix), containsAll(['health', 'users']));
      expect(unregistered(source, files), isEmpty);
    });

    test('syncManifest is idempotent on the synced manifest', () {
      final source = File('lib/routes.dart').readAsStringSync();
      final files = discoverRouteFiles('lib/routes');
      expect(syncManifest(source, files), source);
    });
  });

  test('OpenAPI output covers every registered route', () {
    final paths =
        (OpenApi.fromRoutes(buildApp().routes).toJson()['paths'] as Map).keys;
    expect(
      paths,
      containsAll([
        '/health',
        '/users/{id}',
        '/users',
        '/users/{uid}/tags/{index}',
      ]),
    );
  });

  test('the app serves create/fetch/tags/404/400 end-to-end', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    expect(
      (await client.post(
        '/users',
        json: {
          'id': '1',
          'name': 'Ada',
          'role': 'admin',
          'tags': ['x', 'y'],
        },
      )).status,
      201,
    );
    expect((await client.get('/users/1')).json(), {
      'id': '1',
      'name': 'Ada',
      'role': 'admin',
      'tags': ['x', 'y'],
    });
    expect((await client.get('/users/1/tags/1')).json(), {'tag': 'y'});
    expect((await client.get('/users/999')).status, 404);
    expect((await client.post('/users', json: {'id': '2'})).status, 400);
  });
}
