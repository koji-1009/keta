import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

class Env {}

Response _ok(Context<Env> c) => c.text('ok');

void main() {
  group('a file states what it serves, and the type checks it', () {
    test('every verb binds at the URL its location denotes', () async {
      final app = App<Env>();
      Exported<Env>([
        Get((c) => c.text('got')),
        Post((c) => c.text('posted')),
        Put((c) => c.text('put')),
        Delete((c) => c.text('deleted')),
        Patch((c) => c.text('patched')),
        const Head(_ok),
        const Options(_ok),
      ]).bind(app, const ['users', ':id']);

      final client = TestClient(app, Env());
      expect((await client.get('/users/1')).text(), 'got');
      expect((await client.post('/users/1')).text(), 'posted');
      expect((await client.put('/users/1')).text(), 'put');
      expect((await client.delete('/users/1')).text(), 'deleted');
      expect((await client.patch('/users/1')).text(), 'patched');
    });

    test('the doc travels with the handler that earns it', () {
      final app = App<Env>();
      const Exported<Env>([
        Get(_ok, doc: 'the-get-doc'),
        Post(_ok),
      ]).bind(app, const ['x']);

      final byMethod = {for (final r in app.routes) r.method: r.doc};
      // Together in one value, so a doc cannot end up on a verb the file does
      // not serve, and a rename cannot silently unbind it.
      expect(byMethod['GET'], 'the-get-doc');
      expect(byMethod['POST'], isNull);
    });

    test('the root is an empty template', () async {
      final app = App<Env>();
      Exported<Env>([Get((c) => c.text('root'))]).bind(app, const []);
      expect((await TestClient(app, Env()).get('/')).text(), 'root');
    });
  });

  group('captures are the one thing the tree cannot say', () {
    test('a declared capture supplies the type and the schema', () async {
      final app = App<Env>();
      Exported<Env>(
        [Get((c) => c.text('${c.param<int>('index')}'))],
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

    test('an undeclared capture is a string', () {
      final app = App<Env>();
      const Exported<Env>([Get(_ok)]).bind(app, const ['users', ':id']);
      expect((app.routes.single.segments[1] as CaptureSegment).capture.schema, {
        'type': 'string',
      });
    });
  });

  group('what fails, and when', () {
    test('a file that serves nothing fails at boot, naming the URL', () {
      // It sits in the tree looking like a route and answers 404. The check is
      // on bind rather than the constructor, which costs nothing: a lazy `final
      // exported` only runs its initializer when something first touches it,
      // and the first touch is this bind. Moving it is what lets the
      // constructor be const.
      expect(
        () => const Exported<Env>([]).bind(App<Env>(), const ['users', ':id']),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('/users/:id'),
          ),
        ),
      );
    });

    test("a URL answering a method twice is keta's to catch, not ours", () {
      // Checking it here would duplicate a boot-time check keta already has —
      // and keta names the route, where this could only name a type.
      final app = App<Env>();
      const Exported<Env>([Get(_ok), Get(_ok)]).bind(app, const ['x']);
      expect(
        () => app.compile(Env()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('route conflict'), contains('GET /x')),
          ),
        ),
      );
    });
  });

  test('a route file export is a compile-time constant', () {
    // Nothing needs a constructor body, so the whole declaration is const
    // rather than something built on first touch.
    const a = Exported<Env>([Get(_ok)], captures: {'index': integer});
    const b = Exported<Env>([Get(_ok)], captures: {'index': integer});
    expect(identical(a, b), isTrue, reason: 'canonicalized, so really const');
  });
}
