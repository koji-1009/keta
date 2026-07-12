import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_example/app.dart';
import 'package:keta_example/env.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

Future<Env> bootTestEnv() async {
  // Build the schema from the same migrations the server runs, so the migration
  // files are the single source of truth and are exercised by the suite.
  final db = SqliteDb.memory();
  await applyMigrations(db, directory: 'migrations');
  return Env(db, StdoutLog(flushInterval: Duration.zero));
}

void main() {
  test('create, fetch, and index into a user across both syntaxes', () async {
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

    final got = await client.get('/users/1');
    expect(got.json(), {
      'id': '1',
      'name': 'Ada',
      'role': 'admin',
      'tags': ['x', 'y'],
    });

    final tag = await client.get('/users/1/tags/1');
    expect(tag.json(), {'tag': 'y'});
  });

  test('invalid body is 400, missing user is 404', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    expect((await client.post('/users', json: {'id': '2'})).status, 400);
    expect((await client.get('/users/999')).status, 404);
  });

  test('OpenAPI output mirrors the registered routes', () {
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
}
