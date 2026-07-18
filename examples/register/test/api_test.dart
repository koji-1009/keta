/// The CRUD surface: create/fetch/update/delete, list pagination and role
/// filtering, the custom Role capture, and the validation boundary (bad
/// bodies, duplicate ids, a mismatched PUT id, malformed tags). Security,
/// streaming, and OpenAPI-doc conformance live in security_test.dart,
/// streaming_test.dart, and openapi_test.dart respectively.
library;

import 'package:keta/test.dart';
import 'package:keta_register_example/app.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('create, fetch, and index into a user across both syntaxes', () async {
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

    final got = await client.get('/users/1', headers: admin);
    expect(got.json(), {
      'id': '1',
      'name': 'Ada',
      'role': 'admin',
      'tags': ['x', 'y'],
    });

    final tag = await client.get('/users/1/tags/1', headers: admin);
    expect(tag.json(), {'tag': 'y'});
  });

  test('invalid body is 400, missing user is 404', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    expect(
      (await client.post('/users', headers: admin, json: {'id': '2'})).status,
      400,
    );
    expect((await client.get('/users/999', headers: admin)).status, 404);
  });

  test('creating a user that already exists is 409, not 500', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);
    final body = {
      'id': '1',
      'name': 'Ada',
      'role': 'admin',
      'tags': <String>[],
    };

    expect(
      (await client.post('/users', headers: admin, json: body)).status,
      201,
    );
    // The handler writes no code for this: keta_sqlite turns the engine's
    // uniqueness violation into a Conflict, and recover() renders it. Were the
    // driver's exception to escape instead, this would be an opaque 500 —
    // which is what it was, and what any app copying this example would ship.
    final again = await client.post('/users', headers: admin, json: body);
    expect(again.status, 409);
    expect(again.json(), {'error': 'row already exists'});
  });

  test(
    'list honors the ?limit query and create returns a Location header',
    () async {
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
          'tags': ['x'],
        },
      );
      expect(created.status, 201);
      expect(created.headers['location'], '/users/1');

      await client.post(
        '/users',
        headers: admin,
        json: {'id': '2', 'name': 'Bo', 'role': 'member', 'tags': <String>[]},
      );
      expect(
        ((await client.get('/users', headers: admin)).json()! as Map)['items'],
        hasLength(2),
      );
      expect(
        (((await client.get('/users?limit=1', headers: admin)).json()!
                as Map)['items']
            as List),
        hasLength(1),
      );
    },
  );

  test('pagination clamps out-of-range bounds and pages with offset', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);
    // Three users, ids 1..3 — the list orders by id, so paging is deterministic.
    for (final i in [1, 2, 3]) {
      await client.post(
        '/users',
        headers: admin,
        json: {'id': '$i', 'name': 'U$i', 'role': 'member', 'tags': <String>[]},
      );
    }

    Future<List<String>> page(String q) async {
      final body =
          (await client.get('/users$q', headers: admin)).json()! as Map;
      return [
        for (final u in body['items'] as List) (u as Map)['id'] as String,
      ];
    }

    // Default paging: no query returns the whole (small) set.
    final all = (await client.get('/users', headers: admin)).json()! as Map;
    expect(all['total'], 3);
    expect(await page(''), ['1', '2', '3']);
    // Offset windows the page; total stays the full count.
    expect(await page('?limit=2&offset=1'), ['2', '3']);
    // An offset past the end is an empty page, not a 400 — the honest answer a
    // paging UI that overshoots the last page should get.
    final over =
        (await client.get('/users?offset=99', headers: admin)).json()! as Map;
    expect(over['items'], isEmpty);
    expect(over['total'], 3);
    // A limit above the cap clamps rather than scanning unboundedly (cap 100),
    // and a nonsense negative offset clamps to 0 rather than erroring.
    expect(await page('?limit=9999'), ['1', '2', '3']);
    expect(await page('?offset=-5'), ['1', '2', '3']);
  });

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

  test(
    'the custom Role capture parses a valid role and 400s a bad one',
    () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      await client.post(
        '/users',
        headers: admin,
        json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
      );
      await client.post(
        '/users',
        headers: admin,
        json: {'id': '2', 'name': 'Bo', 'role': 'member', 'tags': <String>[]},
      );
      // Valid role → the capture parses `admin` and the route lists that role.
      final admins =
          (await client.get('/users/by-role/admin', headers: admin)).json()!
              as Map;
      expect(admins['total'], 1);
      expect((admins['items'] as List).single, containsPair('id', '1'));
      // Invalid role → the capture's parse throws BadRequest, so it is a 400 at
      // the boundary, decided by the declaration and never reaching the handler.
      expect(
        (await client.get('/users/by-role/wizard', headers: admin)).status,
        400,
      );
    },
  );

  test('update (PUT) and delete (DELETE) complete the CRUD surface', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    await client.post(
      '/users',
      headers: admin,
      json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
    );
    final put = await client.put(
      '/users/1',
      headers: admin,
      json: {
        'id': '1',
        'name': 'Ada B',
        'age': 30,
        'role': 'member',
        'tags': ['y'],
      },
    );
    expect(put.status, 200);
    expect(
      (await client.get('/users/1', headers: admin)).json(),
      containsPair('name', 'Ada B'),
    );
    expect(
      (await client.put(
        '/users/999',
        headers: admin,
        json: {'id': '999', 'name': 'x', 'role': 'admin', 'tags': <String>[]},
      )).status,
      404,
    );
    expect((await client.delete('/users/1', headers: admin)).status, 204);
    expect((await client.get('/users/1', headers: admin)).status, 404);
    expect((await client.delete('/users/1', headers: admin)).status, 404);
  });

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
    // The row is untouched: no update ran.
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

  test('list returns a nested UserList and filters by ?role', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);
    await client.post(
      '/users',
      headers: admin,
      json: {'id': '1', 'name': 'Ada', 'role': 'admin', 'tags': <String>[]},
    );
    await client.post(
      '/users',
      headers: admin,
      json: {'id': '2', 'name': 'Bo', 'role': 'member', 'tags': <String>[]},
    );

    final all = (await client.get('/users', headers: admin)).json()! as Map;
    expect(all['total'], 2);
    expect(all['items'], hasLength(2));
    expect(
      (await client.get('/users?role=admin', headers: admin)).json()! as Map,
      containsPair('total', 1),
    );
  });
}
