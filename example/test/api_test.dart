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

/// Every request that is not explicitly public needs credentials — the app is
/// secure by default. These mirror lib/auth.dart's demo tokens.
const admin = {'authorization': 'Bearer t-admin'};
const user = {'authorization': 'Bearer t-user'};

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
        ((await client.get('/users', headers: admin)).json()! as Map)['users'],
        hasLength(2),
      );
      expect(
        (((await client.get('/users?limit=1', headers: admin)).json()!
                as Map)['users']
            as List),
        hasLength(1),
      );
    },
  );

  test('OpenAPI output mirrors the registered routes', () {
    // buildOpenApi(), not a hand-rolled fromRoutes: the test must assert on the
    // document tool/openapi.dart actually emits, or the two can drift apart
    // exactly where it matters.
    final paths = (buildOpenApi().toJson()['paths'] as Map).keys;
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
    expect(all['users'], hasLength(2));
    expect(
      (await client.get('/users?role=admin', headers: admin)).json()! as Map,
      containsPair('total', 1),
    );
  });

  group('the middleware order holds', () {
    // Everything that throws must sit below recover, and everything that
    // decorates a response above it. Get that wrong and the failure is quiet:
    // the status is right and the headers a browser needs are missing, so the
    // client reports an opaque CORS error rather than the status it was sent.
    //
    // timeout is the one that catches people out. It does not return a 504, it
    // throws GatewayTimeout — so with recover below it, `chain` skips cors's
    // header callback on the way out and only App._fallback renders the
    // response. A 401 does not exercise this at all (enforceSecurity sits below
    // recover either way), which is why this drives the deadline instead.
    test('a timed-out request still carries CORS headers', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final app = buildApp(requestTimeout: const Duration(milliseconds: 20))
        ..get('/slow', (c) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return c.text('too late');
        }, doc: const RouteDoc(summary: 'Deliberately slow', security: []));

      final r = await TestClient(
        app,
        env,
      ).get('/slow', headers: const {'origin': 'https://app.example.com'});
      expect(r.status, 504);
      expect(
        r.headers['access-control-allow-origin'],
        '*',
        reason:
            'a 504 without CORS headers reaches the browser as a network '
            'error, so the client cannot tell a timeout from an outage',
      );
    });
  });

  group('the security declarations are enforced, not decorative', () {
    test('no credentials is 401, and a bad token is too', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);

      // /users declares no security, so it inherits the secure-by-default
      // global. Forgetting to think about auth fails closed.
      expect((await client.get('/users')).status, 401);
      expect(
        (await client.get(
          '/users',
          headers: const {'authorization': 'Bearer nope'},
        )).status,
        401,
      );
      // Wrong scheme for the route: /metrics wants apiKey, not bearer.
      expect((await client.get('/metrics', headers: admin)).status, 401);
    });

    test('an explicitly public route needs nothing', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      // `security: []`, not "no declaration" — the difference is the whole
      // point of the override.
      expect((await client.get('/health')).status, 200);
    });

    test('the verifier hands the principal to the handler', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      // /whoami reads c.get(principal), which only the bearer verifier sets.
      expect((await client.get('/whoami', headers: admin)).json(), {
        'id': 'ada',
        'admin': true,
      });
      expect((await client.get('/whoami', headers: user)).json(), {
        'id': 'bo',
        'admin': false,
      });
    });

    test('authentication is not authorization', () async {
      final env = await bootTestEnv();
      addTearDown(env.close);
      final client = TestClient(buildApp(), env);
      // Both tokens authenticate. Only one is an admin: 401 says "who are
      // you", 403 says "not you".
      expect((await client.get('/admin/ping', headers: admin)).status, 200);
      expect((await client.get('/admin/ping', headers: user)).status, 403);
      expect((await client.get('/admin/ping')).status, 401);
    });

    test('the document says exactly what the gate does', () {
      final doc = buildOpenApi().toJson();
      Map<String, Object?> op(String path, [String verb = 'get']) =>
          ((doc['paths'] as Map)[path] as Map)[verb] as Map<String, Object?>;

      // Public: no security, and no 401 promised.
      expect(op('/health').containsKey('security'), isFalse);
      expect((op('/health')['responses'] as Map).containsKey('401'), isFalse);
      // Inherits the default.
      expect(op('/users')['security'], [
        {'bearer': <String>[]},
      ]);
      // Overrides it with a different scheme.
      expect(op('/metrics')['security'], [
        {'apiKey': <String>[]},
      ]);
      // Both schemes reached components, carried as data by the declarations.
      expect(
        ((doc['components'] as Map)['securitySchemes'] as Map).keys,
        unorderedEquals(['bearer', 'apiKey']),
      );
    });
  });

  test('CORS preflight and the metrics endpoint work', () async {
    final env = await bootTestEnv();
    addTearDown(env.close);
    final client = TestClient(buildApp(), env);

    final preflight = await client.options('/users');
    expect(preflight.status, 204);
    expect(preflight.headers['access-control-allow-origin'], '*');

    await client.get('/users/999', headers: admin); // record a request
    expect(
      (await client.get(
        '/metrics',
        headers: const {'x-api-key': 'k-metrics'},
      )).text(),
      contains('keta_requests_total'),
    );
  });
}
