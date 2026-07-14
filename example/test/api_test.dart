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

  test('list honors the ?limit query and create returns a Location header', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    final created = await client.post(
      '/users',
      json: {
        'id': '1',
        'name': 'Ada',
        'role': 'admin',
        'tags': ['x'],
      },
    );
    expect(created.status, 201);
    expect(created.headers['location'], '/users/1');

    await client.post(
      '/users',
      json: {'id': '2', 'name': 'Bo', 'role': 'member', 'tags': <String>[]},
    );
    expect(((await client.get('/users')).json()! as Map)['users'], hasLength(2));
    expect(
      (((await client.get('/users?limit=1')).json()! as Map)['users'] as List),
      hasLength(1),
    );
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

  test('update (PUT) and delete (DELETE) complete the CRUD surface', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    await client.post(
      '/users',
      json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
    );
    final put = await client.put(
      '/users/1',
      json: {
        'id': '1',
        'name': 'Ada B',
        'age': 30,
        'role': 'member',
        'tags': ['y'],
      },
    );
    expect(put.status, 200);
    expect((await client.get('/users/1')).json(), containsPair('name', 'Ada B'));
    expect(
      (await client.put(
        '/users/999',
        json: {'id': '999', 'name': 'x', 'role': 'admin', 'tags': <String>[]},
      )).status,
      404,
    );
    expect((await client.delete('/users/1')).status, 204);
    expect((await client.get('/users/1')).status, 404);
    expect((await client.delete('/users/1')).status, 404);
  });

  test('list returns a nested UserList and filters by ?role', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);
    await client.post(
      '/users',
      json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
    );
    await client.post(
      '/users',
      json: {'id': '2', 'name': 'Bo', 'role': 'member', 'tags': <String>[]},
    );

    final all = (await client.get('/users')).json()! as Map;
    expect(all['total'], 2);
    expect(all['users'], hasLength(2));
    expect((await client.get('/users?role=admin')).json()! as Map, containsPair('total', 1));
  });

  test('CORS preflight and the metrics endpoint work', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    final preflight = await client.options('/users');
    expect(preflight.status, 204);
    expect(preflight.headers['access-control-allow-origin'], '*');

    await client.get('/users/999'); // record a request
    expect((await client.get('/metrics')).text(), contains('keta_requests_total'));
  });
}
