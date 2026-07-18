/// `Exported`/`Serve` binding a discovered route file to the app: method
/// slots, capture typing, directory-scope middleware nesting, and the
/// runtime template-to-path translation (`routeSegments`) that binding
/// itself uses.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

class Env {}

Response _ok(Context<Env> c) => c.text('ok');

void main() {
  group('a file states what it serves, and the type checks it', () {
    test('every slot binds at the URL its location denotes', () async {
      // Every slot, so a method that stopped binding is caught here. There is
      // no exhaustiveness to lean on: the slots are the closed set of methods
      // keta binds, and this is what holds bind to all of them.
      final app = App<Env>();
      Exported<Env>(
        get: Serve((c) => c.text('got')),
        post: Serve((c) => c.text('posted')),
        put: Serve((c) => c.text('put')),
        delete: Serve((c) => c.text('deleted')),
        patch: Serve((c) => c.text('patched')),
        head: const Serve(_ok),
        options: const Serve(_ok),
      ).bind(app, const ['users', ':id']);

      expect(app.routes.map((r) => r.method).toSet(), {
        'GET',
        'POST',
        'PUT',
        'DELETE',
        'PATCH',
        'HEAD',
        'OPTIONS',
      });
      final client = TestClient(app, Env());
      expect((await client.get('/users/1')).text(), 'got');
      expect((await client.post('/users/1')).text(), 'posted');
      expect((await client.put('/users/1')).text(), 'put');
      expect((await client.delete('/users/1')).text(), 'deleted');
      expect((await client.patch('/users/1')).text(), 'patched');
    });

    test('the doc travels with the handler that earns it', () {
      final app = App<Env>();
      const Exported<Env>(
        get: Serve(_ok, doc: 'the-get-doc'),
        post: Serve(_ok),
      ).bind(app, const ['x']);

      final byMethod = {for (final r in app.routes) r.method: r.doc};
      // Together in one value, so a doc cannot end up on a method the file does
      // not serve, and a rename cannot silently unbind it.
      expect(byMethod['GET'], 'the-get-doc');
      expect(byMethod['POST'], isNull);
    });

    test('an unfilled slot is a method the URL does not answer', () {
      final app = App<Env>();
      const Exported<Env>(get: Serve(_ok)).bind(app, const ['x']);
      expect(app.routes.map((r) => r.method), ['GET']);
    });

    test('the root is an empty template', () async {
      final app = App<Env>();
      Exported<Env>(get: Serve((c) => c.text('root'))).bind(app, const []);
      expect((await TestClient(app, Env()).get('/')).text(), 'root');
    });
  });

  group('captures are the one thing the tree cannot say', () {
    test('a declared capture supplies the type and the schema', () async {
      final app = App<Env>();
      Exported<Env>(
        get: Serve((c) => c.text('${c.param<int>('index')}')),
        captures: {'index': integer},
      ).bind(app, const ['tags', ':index']);

      expect((await TestClient(app, Env()).get('/tags/7')).text(), '7');
      // Reaches the contract, which `:index` in the string syntax never could.
      expect((app.routes.single.segments[1] as CaptureSegment).capture.schema, {
        'type': 'integer',
      });
      // And is enforced at the boundary, not by the handler remembering to.
      expect((await TestClient(app, Env()).get('/tags/abc')).status, 400);
    });

    test('a capture belongs to the URL, so every method carries it', () {
      // Which is why captures sits beside the slots rather than inside one:
      // /users/:id has an id whether it is fetched, replaced or deleted.
      final app = App<Env>();
      const Exported<Env>(
        get: Serve(_ok),
        put: Serve(_ok),
        delete: Serve(_ok),
        captures: {'id': integer},
      ).bind(app, const ['users', ':id']);

      expect(app.routes, hasLength(3));
      for (final route in app.routes) {
        expect(
          (route.segments[1] as CaptureSegment).capture.schema,
          {'type': 'integer'},
          reason: '${route.method} must carry the same parameter',
        );
      }
    });

    test('an undeclared capture is a string', () {
      final app = App<Env>();
      const Exported<Env>(get: Serve(_ok)).bind(app, const ['users', ':id']);
      expect((app.routes.single.segments[1] as CaptureSegment).capture.schema, {
        'type': 'string',
      });
    });
  });

  test('a file that serves nothing fails at boot, naming the URL', () {
    // It sits in the tree looking like a route and answers 404. The check is on
    // bind rather than the constructor, which costs nothing: a lazy `final
    // exported` only runs its initializer when something first touches it, and
    // the first touch is this bind. Moving it is what lets the constructor be
    // const.
    //
    // The other way a file could be wrong — one URL answering a method twice —
    // has no test because it has no syntax: a slot is one named argument, and
    // passing it twice does not compile. As a list it compiled, and only keta's
    // boot-time `route conflict` caught it.
    expect(
      () => const Exported<Env>().bind(App<Env>(), const ['users', ':id']),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('/users/:id'),
        ),
      ),
    );
  });

  group('directory scopes wrap the handler in nesting order', () {
    // Each middleware records its name before delegating; the handler records
    // itself last and returns the trace. The string it returns is the exact
    // order the pipeline ran.
    Middleware<Env> mark(String name, List<String> trace) => (c, next) {
      trace.add(name);
      return next(c);
    };

    test('app-wide first, then outer→inner scope, then the handler', () async {
      final trace = <String>[];
      final app = App<Env>()..use(mark('app', trace));
      Exported<Env>(
        get: Serve((c) {
          trace.add('handler');
          return c.text(trace.join('>'));
        }),
      ).bind(
        app,
        const ['admin', 'audit', 'log'],
        [
          ScopedMiddleware([mark('root', trace)]),
          ScopedMiddleware([mark('admin', trace)]),
        ],
      );

      final res = await TestClient(app, Env()).get('/admin/audit/log');
      // The order the task pins: app-wide wraps the whole dispatch, the root
      // directory scope wraps the admin scope, and both wrap the handler.
      expect(res.text(), 'app>root>admin>handler');
    });

    test('within one scope, the list order is the run order', () {
      final trace = <String>[];
      final app = App<Env>();
      Exported<Env>(
        get: Serve((c) {
          trace.add('handler');
          return c.text('ok');
        }),
      ).bind(
        app,
        const ['x'],
        [
          ScopedMiddleware([mark('first', trace), mark('second', trace)]),
        ],
      );

      return TestClient(app, Env()).get('/x').then((_) {
        expect(trace, ['first', 'second', 'handler']);
      });
    });

    test('a scope can short-circuit before the handler', () async {
      // The whole point of scoping authorization to a subtree: the middleware
      // answers without the handler running.
      final app = App<Env>();
      var handlerRan = false;
      Exported<Env>(
        get: Serve((c) {
          handlerRan = true;
          return c.text('reached');
        }),
      ).bind(
        app,
        const ['admin', 'secret'],
        [
          ScopedMiddleware([(c, next) => c.text('denied')]),
        ],
      );

      final res = await TestClient(app, Env()).get('/admin/secret');
      expect(res.text(), 'denied');
      expect(handlerRan, isFalse);
    });

    test('no scope binds exactly as before', () async {
      final app = App<Env>();
      Exported<Env>(get: Serve((c) => c.text('plain'))).bind(app, const ['x']);
      expect((await TestClient(app, Env()).get('/x')).text(), 'plain');
    });
  });

  test('a route file export is a compile-time constant', () {
    // Nothing needs a constructor body, so the whole declaration is const
    // rather than something built on first touch.
    const a = Exported<Env>(get: Serve(_ok), captures: {'index': integer});
    const b = Exported<Env>(get: Serve(_ok), captures: {'index': integer});
    expect(identical(a, b), isTrue, reason: 'canonicalized, so really const');
  });

  // Moved verbatim from manifest_test.dart: `routeSegments` is `bind`'s own
  // template-to-path translation (export.dart is its only caller), not a
  // manifest-emission concern, so its direct unit tests belong in this
  // file's charter rather than manifest_test.dart's.
  group('routeSegments turns a template into a path', () {
    test('a capture the file does not mention is a string', () {
      final segments = routeSegments(const ['users', ':id']);
      expect((segments[0] as LiteralSegment).value, 'users');
      final capture = (segments[1] as CaptureSegment).capture;
      expect(capture.name, 'id');
      expect(capture.schema, {'type': 'string'});
    });

    test('a declared capture supplies the type, and is named by the tree', () {
      final segments = routeSegments(
        const [':index'],
        const {'index': integer},
      );
      final capture = (segments.single as CaptureSegment).capture;
      // The name comes from the file's location; the declaration is about the
      // type alone, so the two cannot disagree.
      expect(capture.name, 'index');
      expect(capture.schema, {'type': 'integer'});
    });

    test('a declaration for a part the tree does not have is inert', () {
      final segments = routeSegments(const ['users'], const {'id': integer});
      expect(segments.single, isA<LiteralSegment>());
    });

    test('the root is no segments', () {
      expect(routeSegments(const []), isEmpty);
    });
  });
}
