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
      Exported<Env>([
        const Get(_ok, doc: 'the-get-doc'),
        const Post(_ok),
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
      Exported<Env>([const Get(_ok)]).bind(app, const ['users', ':id']);
      expect((app.routes.single.segments[1] as CaptureSegment).capture.schema, {
        'type': 'string',
      });
    });
  });

  group('what cannot be built', () {
    test('a file that serves nothing', () {
      // It would sit in the tree looking like a route and answer 404. Refused
      // where it is written, not discovered at request time.
      expect(() => Exported<Env>(const []), throwsA(isA<ArgumentError>()));
    });

    test('one URL answering a method twice', () {
      // Which one wins is a question with no answer; keta's own boot-time check
      // would catch it later, but the file is where the mistake is.
      expect(
        () => Exported<Env>([const Get(_ok), const Get(_ok)]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('answers a method once'),
          ),
        ),
      );
    });
  });
}
