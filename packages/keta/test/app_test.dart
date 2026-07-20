/// Owns the App surface below routing dispatch: verb registration and the 405
/// for unregistered methods, typed-DSL capture coercion for number/bool, route
/// introspection via App.routes, and the fail-fast validation on empty capture
/// names and bad serve arguments.
library;

import 'dart:async';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

class _FakeTransport implements Transport {
  @override
  Future<TransportServer> bind(
    int port,
    FutureOr<Response> Function(TransportRequest) onRequest,
  ) => throw UnimplementedError();
}

void main() {
  test(
    'typed-DSL double and bool captures parse, rejecting bad input',
    () async {
      final app = App<Env>();
      app
          .on(root.segments('m').capture(number).capture(boolean))
          .get((c, p) => c.json({'d': p.$1, 'b': p.$2}));
      final client = TestClient(app, newEnv());

      expect((await client.get('/m/2.5/true')).json(), {'d': 2.5, 'b': true});
      expect((await client.get('/m/x/true')).status, 400);
      expect((await client.get('/m/2.5/yes')).status, 400);
    },
  );

  test(
    'put/delete/patch/head register and dispatch; other verbs are 405',
    () async {
      final app = App<Env>();
      app.put('/r', (c) => c.text('put'));
      app.delete('/r', (c) => c.text('delete'));
      app.patch('/r', (c) => c.text('patch'));
      app.head('/r', (c) => c.text(''));
      final client = TestClient(app, newEnv());

      expect((await client.put('/r')).text(), 'put');
      expect((await client.delete('/r')).text(), 'delete');
      expect((await client.patch('/r')).text(), 'patch');
      expect((await client.head('/r')).status, 200);
      expect((await client.get('/r')).status, 405);
    },
  );

  test(
    'a 405 unions the Allow header across a literal and a capture path',
    () async {
      final app = App<Env>();
      // Both terminate on /items/active: the literal branch (GET) and the
      // capture branch (POST). A method that hits neither must advertise both.
      app.get('/items/active', (c) => c.text('literal'));
      app.post('/items/:id', (c) => c.text('capture'));
      final client = TestClient(app, newEnv());

      final r = await client.delete('/items/active');
      expect(r.status, 405);
      // Union, literal branch first: GET (from /items/active), then POST (from
      // /items/:capture).
      expect(r.headers['allow'], 'GET, POST');
    },
  );

  test('App.routes exposes registered routes in order with their docs', () {
    const getDoc = RouteDoc(success: Success(), summary: 'get-user');
    const postDoc = RouteDoc(success: Success(), summary: 'post-p');
    final app = App<Env>();
    app.get('/users/:id', (c) => c.text(''), doc: getDoc);
    app
        .on(root.segments('p').capture(integer))
        .post((c, p) => c.text(''), doc: postDoc);
    final routes = app.routes;
    expect(
      [for (final r in routes) (r.method, r.template)],
      [('GET', '/users/:id'), ('POST', '/p/:p0')],
    );
    expect(routes[0].doc, same(getDoc));
    expect(routes[1].doc, same(postDoc));
  });

  test('an empty capture name in a pattern fails fast', () {
    final app = App<Env>();
    expect(() => app.get('/x/:', (c) => c.text('')), throwsArgumentError);
    expect(() => app.group('/:'), throwsArgumentError);
  });

  test(
    'serve rejects isolates < 1 and a transport with isolates > 1',
    () async {
      final app = App<Env>();
      var booted = false;
      Future<Env> boot() async {
        booted = true;
        return newEnv();
      }

      await expectLater(app.serve(boot, isolates: 0), throwsArgumentError);
      await expectLater(
        app.serve(boot, isolates: 2, transport: _FakeTransport()),
        throwsArgumentError,
      );
      expect(booted, isFalse);
    },
  );
}
