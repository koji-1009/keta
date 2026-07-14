import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

/// A log that records lines in memory, for asserting on middleware output.
class MemLog implements Log {
  MemLog([this.lines = const []]) : _baked = const {};
  MemLog._(this.lines, this._baked);
  final List<Map<String, Object?>> lines;
  final Map<String, Object?> _baked;

  void _add(String level, String msg, Map<String, Object?> fields) =>
      lines.add({'level': level, 'msg': msg, ..._baked, ...fields});

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('debug', msg, fields);
  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('info', msg, fields);
  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('warn', msg, fields);
  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) => _add('error', msg, {...fields, if (error != null) 'error': '$error'});
  @override
  Future<void> flush() async {}
  @override
  Log withFields(Map<String, Object?> fields) =>
      MemLog._(lines, {..._baked, ...fields});
}

class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

Env newEnv() => Env(MemLog(<Map<String, Object?>>[]));

enum Shade { red, green }

void main() {
  group('routing — string syntax', () {
    test('static and captured paths dispatch', () async {
      final app = App<Env>();
      app.get('/health', (c) => c.text('ok'));
      app.get('/users/:id', (c) => c.text('user ${c.param<String>('id')}'));
      final client = TestClient(app, newEnv());

      expect((await client.get('/health')).text(), 'ok');
      expect((await client.get('/users/42')).text(), 'user 42');
    });

    test(
      'c.param parses typed values and rejects bad input with 400',
      () async {
        final app = App<Env>();
        app.get('/n/:n', (c) => c.json({'n': c.param<int>('n')}));
        final client = TestClient(app, newEnv());

        expect((await client.get('/n/7')).json(), {'n': 7});
        expect((await client.get('/n/nope')).status, 400);
      },
    );
  });

  group('routing — typed DSL', () {
    test('captures parse into the handler tuple', () async {
      final app = App<Env>();
      app
          .on(
            root
                .segments('users')
                .capture(string('uid'))
                .segments('posts')
                .capture(integer('postId')),
          )
          .post((c, p) => c.json({'uid': p.$1, 'postId': p.$2}));
      final client = TestClient(app, newEnv());

      expect((await client.post('/users/ada/posts/9')).json(), {
        'uid': 'ada',
        'postId': 9,
      });
    });

    test('a non-parsable typed capture yields 400', () async {
      final app = App<Env>();
      app
          .on(root.segments('n').capture(integer))
          .get((c, p) => c.json({'n': p.$1}));
      final client = TestClient(app, newEnv());

      expect((await client.get('/n/x')).status, 400);
    });

    test('segments batches a "/"-separated run into literal segments', () async {
      final app = App<Env>();
      app
          .on(root.segments('api/v1/ping'))
          .get((c, _) => c.text('pong'));
      final client = TestClient(app, newEnv());

      expect((await client.get('/api/v1/ping')).text(), 'pong');
    });

    test('segments rejects empty parts and ":"-prefixed literals', () {
      expect(() => root.segments('a//b'), throwsArgumentError); // doubled slash
      expect(() => root.segments('/a'), throwsArgumentError); // leading slash
      expect(() => root.segments('a/'), throwsArgumentError); // trailing slash
      expect(() => root.segments(':id'), throwsArgumentError); // capture vocab
    });

    test('a custom capture drives the tuple and BadRequest becomes 400', () async {
      final shade = Capture<Shade>(
        (s) =>
            Shade.values.asNameMap()[s] ??
            (throw BadRequest('unknown shade: $s')),
        schema: {
          'type': 'string',
          'enum': ['red', 'green'],
        },
      );
      final app = App<Env>();
      app
          .on(root.segments('c').capture(shade('shade')))
          .get((c, (Shade,) p) => c.text(p.$1.name));
      final client = TestClient(app, newEnv());

      expect((await client.get('/c/green')).text(), 'green');
      expect((await client.get('/c/purple')).status, 400);
    });
  });

  group('group prefix captures and path decoding', () {
    test(
      'a captured group prefix is readable via c.param (string form)',
      () async {
        final app = App<Env>();
        app
            .group('/tenants/:tid')
            .get(
              '/users/:uid',
              (c) => c.json({
                'tid': c.param<String>('tid'),
                'uid': c.param<String>('uid'),
              }),
            );
        final client = TestClient(app, newEnv());

        expect((await client.get('/tenants/acme/users/42')).json(), {
          'tid': 'acme',
          'uid': '42',
        });
      },
    );

    test('a captured group prefix aligns with the typed tuple', () async {
      final app = App<Env>();
      app
          .group('/t/:tid')
          .on(root.segments('p').capture(integer))
          .get((c, p) => c.json({'tid': c.param<String>('tid'), 'p': p.$1}));
      final client = TestClient(app, newEnv());

      expect((await client.get('/t/acme/p/42')).json(), {
        'tid': 'acme',
        'p': 42,
      });
    });

    test('captured segments are percent-decoded', () async {
      final app = App<Env>();
      app.get('/u/:id', (c) => c.text(c.param<String>('id')));
      final client = TestClient(app, newEnv());

      expect((await client.get('/u/john%40doe.com')).text(), 'john@doe.com');
    });
  });

  group('match precedence and errors', () {
    test('literal beats capture, with backtracking', () async {
      final app = App<Env>();
      app.get('/users/me', (c) => c.text('me'));
      app.get('/users/:id', (c) => c.text('id:${c.param<String>('id')}'));
      app.get('/:x/c', (c) => c.text('x:${c.param<String>('x')}'));
      app.get('/a/b', (c) => c.text('ab'));
      final client = TestClient(app, newEnv());

      expect((await client.get('/users/me')).text(), 'me');
      expect((await client.get('/users/7')).text(), 'id:7');
      // /a/c has no literal /a/* leaf, so the capture branch /:x/c must match.
      expect((await client.get('/a/c')).text(), 'x:a');
      expect((await client.get('/a/b')).text(), 'ab');
    });

    test('unknown path is 404, wrong method is 405', () async {
      final app = App<Env>();
      app.get('/only', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      expect((await client.get('/missing')).status, 404);
      expect((await client.post('/only')).status, 405);
    });

    test('duplicate capture names in one path fail fast', () {
      final app = App<Env>();
      expect(
        () => app.get('/u/:id/p/:id', (c) => c.text('x')),
        throwsStateError,
      );
    });

    test('duplicate method+template fails fast at compile', () {
      final app = App<Env>();
      app.get('/dup/:a', (c) => c.text('1'));
      app.get('/dup/:b', (c) => c.text('2')); // same template, different name
      expect(() => TestClient(app, newEnv()), throwsStateError);
    });
  });

  group('middleware', () {
    test('app then group middleware run in registration order', () async {
      final order = <String>[];
      Middleware<Env> tag(String name) => (c, next) async {
        order.add('>$name');
        final r = await next(c);
        order.add('<$name');
        return r;
      };
      final app = App<Env>()..use(tag('app'));
      app.group('/admin')
        ..use(tag('grp'))
        ..get('/x', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      await client.get('/admin/x');
      expect(order, ['>app', '>grp', '<grp', '<app']);
    });

    test('recover maps KetaException to its status and body', () async {
      final app = App<Env>()..use(recover());
      app.get('/boom', (c) => throw const KetaException.status(418, 'teapot'));
      final client = TestClient(app, newEnv());

      final r = await client.get('/boom');
      expect(r.status, 418);
      expect(r.json(), {'error': 'teapot'});
    });

    test(
      'last-resort fallback converts uncaught errors without recover',
      () async {
        final app = App<Env>(); // no recover()
        app.get('/keta', (c) => throw const NotFound('gone'));
        app.get('/other', (c) => throw StateError('leak me'));
        final client = TestClient(app, newEnv());

        expect((await client.get('/keta')).json(), {'error': 'gone'});
        final other = await client.get('/other');
        expect(other.status, 500);
        expect(other.text(), '');
      },
    );

    test('cors attaches allow-origin for a listed origin', () async {
      final app = App<Env>()..use(cors(allowOrigins: ['https://a.example']));
      app.get('/x', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      final r = await client.get(
        '/x',
        headers: {'origin': 'https://a.example'},
      );
      expect(r.headers['access-control-allow-origin'], 'https://a.example');

      final denied = await client.get(
        '/x',
        headers: {'origin': 'https://evil'},
      );
      expect(
        denied.headers.containsKey('access-control-allow-origin'),
        isFalse,
      );
    });

    test(
      'app-level middleware wraps 404/405 (CORS preflight + access log)',
      () async {
        final env = newEnv();
        final app = App<Env>()
          ..use(accessLog())
          ..use(cors(allowOrigins: ['https://a.example']));
        app.get('/x', (c) => c.text('ok'));
        final client = TestClient(app, env);

        // Preflight to an unregistered method is answered by cors, not 405.
        final pre = await client.options(
          '/x',
          headers: {'origin': 'https://a.example'},
        );
        expect(pre.status, 204);
        expect(pre.headers['access-control-allow-origin'], 'https://a.example');

        // A 404 still flows through accessLog.
        final missing = await client.get('/missing');
        expect(missing.status, 404);
        final lines = (env.log as MemLog).lines;
        expect(
          lines.any((l) => l['msg'] == 'request' && l['status'] == 404),
          isTrue,
        );
      },
    );

    test('tracing extracts a valid traceparent', () async {
      final app = App<Env>()..use(tracing());
      app.get('/t', (c) {
        final t = c.tryGet(traceKey);
        return c.json({'trace': t?.traceId});
      });
      final client = TestClient(app, newEnv());

      final r = await client.get(
        '/t',
        headers: {
          'traceparent':
              '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
        },
      );
      expect(r.json(), {'trace': '0af7651916cd43dd8448eb211c80319c'});
    });
  });

  group('body and failure modes', () {
    test('c.body decodes JSON and is cached', () async {
      final app = App<Env>();
      app.post('/echo', (c) async => c.json(await c.body()));
      final client = TestClient(app, newEnv());

      expect((await client.post('/echo', json: {'a': 1})).json(), {'a': 1});
    });

    testBothModes('recover handles both failure shapes', (mode) async {
      final app = App<Env>()..use(recover());
      app.get(
        '/f',
        (Context<Env> c) =>
            mode.wrap(() => throw const BadRequest('bad'))(),
      );
      final client = TestClient(app, newEnv());

      final r = await client.get('/f');
      expect(r.status, 400);
      expect(r.json(), {'error': 'bad'});
    });
  });

  group('Response', () {
    test('rejects an invalid body type unconditionally (not assert-only)', () {
      expect(
        () => Response(200, body: {'a': 1}),
        throwsA(isA<ArgumentError>()),
      );
      expect(Response(200, body: 'ok').body, 'ok');
      expect(Response(200, body: const [1, 2]).body, const [1, 2]);
    });
  });

  group('testContext', () {
    test('builds a usable context for a handler', () async {
      final c = testContext(newEnv(), path: '/x', headers: {'X-A': 'b'});
      expect(c.header('x-a'), 'b');
      expect(c.text('hi').status, 200);
    });
  });

  group('query parameters', () {
    test('query is required (400), tryQuery is optional, queryAll repeats', () async {
      final app = App<Env>();
      app.get(
        '/s',
        (c) => c.json({
          'page': c.query<int>('page'),
          'q': c.tryQuery<String>('q'),
          'tags': c.queryAll<String>('tag'),
        }),
      );
      final client = TestClient(app, newEnv());

      expect((await client.get('/s?page=2&tag=a&tag=b')).json(), {
        'page': 2,
        'q': null,
        'tags': ['a', 'b'],
      });
      expect((await client.get('/s')).status, 400); // required absent
      expect((await client.get('/s?page=x')).status, 400); // unparseable
    });
  });

  group('multi-value headers', () {
    test('a response keeps every value for one header (set-cookie)', () {
      final r = Response(
        200,
        headers: {
          'set-cookie': ['a=1', 'b=2'],
        },
      );
      expect(r.headers['set-cookie'], ['a=1', 'b=2']);
    });

    test('header returns the first value, headerAll returns all', () {
      final c = testContext(newEnv(), headers: {'accept': 'text/html'});
      expect(c.header('accept'), 'text/html');
      expect(c.headerAll('accept'), ['text/html']);
      expect(c.header('missing'), isNull);
      expect(c.headerAll('missing'), isEmpty);
    });

    test('c.json merges extra headers over the content type', () {
      final r = testContext(newEnv()).json(
        {'ok': true},
        status: 201,
        headers: {
          'location': ['/x'],
        },
      );
      expect(r.status, 201);
      expect(r.headers['location'], ['/x']);
      expect(r.headers['content-type'], ['application/json; charset=utf-8']);
    });
  });
}
