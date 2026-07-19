/// Owns the router-facing contract: string and typed-DSL routing, match
/// precedence and fail-fast errors, middleware ordering, request body/failure
/// modes, Response header validation, and query/header accessors.
library;

import 'dart:async';
import 'dart:convert';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

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

    test(
      'segments batches a "/"-separated run into literal segments',
      () async {
        final app = App<Env>();
        app.on(root.segments('api/v1/ping')).get((c, _) => c.text('pong'));
        final client = TestClient(app, newEnv());

        expect((await client.get('/api/v1/ping')).text(), 'pong');
      },
    );

    test('segments rejects empty parts and ":"-prefixed literals', () {
      expect(() => root.segments('a//b'), throwsArgumentError); // doubled slash
      expect(() => root.segments('/a'), throwsArgumentError); // leading slash
      expect(() => root.segments('a/'), throwsArgumentError); // trailing slash
      expect(() => root.segments(':id'), throwsArgumentError); // capture vocab
    });

    test(
      'a custom capture drives the tuple and BadRequest becomes 400',
      () async {
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
      },
    );
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

    test('405 carries an Allow header listing the path methods', () async {
      final app = App<Env>();
      app.get('/r', (c) => c.text('g'));
      app.delete('/r', (c) => c.text('d'));
      final client = TestClient(app, newEnv());

      final r = await client.post('/r'); // POST not registered
      expect(r.status, 405);
      final allow = (r.headers['allow'] ?? '').split(', ').toSet();
      expect(allow, {'GET', 'DELETE'});
    });

    test('routeTemplate is the matched template, null when unmatched', () async {
      final seen = <String?>[];
      final app = App<Env>()
        ..use((c, next) {
          seen.add(c.routeTemplate);
          return next(c);
        });
      app.get('/users/:id', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      await client.get('/users/7');
      await client.get('/missing');
      // route (for logs) always has a value; routeTemplate is null on no match.
      expect(seen, ['/users/:id', null]);
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

        // A real preflight (OPTIONS + access-control-request-method) to an
        // unregistered method is answered by cors, not 405.
        final pre = await client.options(
          '/x',
          headers: {
            'origin': 'https://a.example',
            'access-control-request-method': 'GET',
          },
        );
        expect(pre.status, 204);
        expect(pre.headers['access-control-allow-origin'], 'https://a.example');
        expect(pre.headers.containsKey('access-control-allow-methods'), isTrue);

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

    test('a plain OPTIONS falls through to a registered OPTIONS route', () async {
      final app = App<Env>()..use(cors(allowOrigins: ['*']));
      app.options('/x', (c) => c.text('user-options'));
      final client = TestClient(app, newEnv());

      // No access-control-request-method → not a preflight → reaches the route.
      final r = await client.options('/x', headers: {'origin': 'https://a'});
      expect(r.status, 200);
      expect(r.text(), 'user-options');
    });

    test(
      'echoing a specific origin adds Vary: Origin; wildcard does not',
      () async {
        final specific = App<Env>()
          ..use(cors(allowOrigins: ['https://a.example']));
        specific.get('/x', (c) => c.text('ok'));
        final rSpecific = await TestClient(
          specific,
          newEnv(),
        ).get('/x', headers: {'origin': 'https://a.example'});
        expect(rSpecific.headers['vary'], 'Origin');

        final wild = App<Env>()..use(cors(allowOrigins: ['*']));
        wild.get('/x', (c) => c.text('ok'));
        final rWild = await TestClient(
          wild,
          newEnv(),
        ).get('/x', headers: {'origin': 'https://a.example'});
        expect(rWild.headers['access-control-allow-origin'], '*');
        expect(rWild.headers.containsKey('vary'), isFalse);
      },
    );

    test(
      'cors options project onto credentials, max-age, expose-headers',
      () async {
        final app = App<Env>()
          ..use(
            cors(
              allowOrigins: ['https://a.example'],
              allowCredentials: true,
              maxAge: const Duration(minutes: 10),
              exposeHeaders: ['x-total', 'x-page'],
            ),
          );
        app.get('/x', (c) => c.text('ok'));
        final client = TestClient(app, newEnv());
        const origin = {'origin': 'https://a.example'};

        // Actual response carries credentials + expose-headers, not max-age.
        final actual = await client.get('/x', headers: origin);
        expect(actual.headers['access-control-allow-credentials'], 'true');
        expect(
          actual.headers['access-control-expose-headers'],
          'x-total, x-page',
        );
        expect(actual.headers.containsKey('access-control-max-age'), isFalse);

        // Preflight carries max-age (seconds), not expose-headers.
        final pre = await client.options(
          '/x',
          headers: {...origin, 'access-control-request-method': 'GET'},
        );
        expect(pre.headers['access-control-max-age'], '600');
        expect(pre.headers['access-control-allow-credentials'], 'true');
        expect(
          pre.headers.containsKey('access-control-expose-headers'),
          isFalse,
        );
      },
    );
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
        (Context<Env> c) => mode.wrap(() => throw const BadRequest('bad'))(),
      );
      final client = TestClient(app, newEnv());

      final r = await client.get('/f');
      expect(r.status, 400);
      expect(r.json(), {'error': 'bad'});
    });

    test('a non-Keta body-stream error is sticky across re-reads', () async {
      // A single-subscription body that fails with a plain I/O-style error:
      // the second read must reproduce that same error deterministically, not
      // an opaque "Stream already listened" StateError.
      Stream<List<int>> ioBoom() async* {
        yield const [1, 2, 3];
        throw const _IoBoom();
      }

      final app = App<Env>();
      app.post('/x', (c) async {
        final errors = <String>[];
        for (var i = 0; i < 2; i++) {
          try {
            await c.bodyBytes();
          } catch (e) {
            errors.add(e.runtimeType.toString());
          }
        }
        return c.json(errors);
      });
      final router = app.compile(newEnv());
      final response = await router.dispatch(_StreamBodyRequest(ioBoom()));
      final bytes = await switch (response.body) {
        String() => Future.value(utf8.encode(response.body as String)),
        List<int>() => Future.value(response.body as List<int>),
        _ => (response.body as Stream<List<int>>).expand((c) => c).toList(),
      };
      expect(jsonDecode(utf8.decode(bytes)), ['_IoBoom', '_IoBoom']);
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

    test('a header value may carry HTAB but never CR/LF or other controls', () {
      // RFC 9110 §5.5 permits HTAB in a field value.
      final ok = Response(
        200,
        headers: {
          'x-tabbed': ['a\tb'],
        },
      );
      expect(ok.headers['x-tabbed'], ['a\tb']);

      // CR, LF, and the other controls remain rejected (response splitting).
      for (final bad in ['a\rb', 'a\nb', 'a b', 'ab']) {
        expect(
          () => Response(
            200,
            headers: {
              'x-bad': [bad],
            },
          ),
          throwsA(isA<ArgumentError>()),
        );
      }
      // A tab in a header *name* is still rejected (names are tokens).
      expect(
        () => Response(
          200,
          headers: {
            'x\tname': ['v'],
          },
        ),
        throwsA(isA<ArgumentError>()),
      );
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
    test(
      'query is required (400), tryQuery is optional, queryAll repeats',
      () async {
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
      },
    );
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

  group('copyWith header semantics', () {
    final base = Response(
      200,
      headers: {
        'x-a': ['1'],
        'x-b': ['2'],
      },
    );

    test('headers: replaces the map wholesale (the way to remove one)', () {
      final r = base.copyWith(
        headers: {
          'x-c': ['3'],
        },
      );
      expect(r.headers, {
        'x-c': ['3'],
      });
    });

    test('addHeaders: merges over the existing map, supplied name wins', () {
      final r = base.copyWith(
        addHeaders: {
          'x-b': ['9'],
          'x-c': ['3'],
        },
      );
      expect(r.headers, {
        'x-a': ['1'],
        'x-b': ['9'],
        'x-c': ['3'],
      });
    });

    test('addHeaders still rejects control characters in the additions', () {
      expect(
        () => base.copyWith(
          addHeaders: {
            'x-evil': ['a\r\nb'],
          },
        ),
        throwsArgumentError,
      );
    });

    test('headers and addHeaders together is an authoring defect', () {
      expect(
        () => base.copyWith(
          headers: {
            'x-c': ['3'],
          },
          addHeaders: {
            'x-d': ['4'],
          },
        ),
        throwsArgumentError,
      );
    });
  });
}

/// A plain (non-Keta) failure, standing in for an I/O error on the body stream.
class _IoBoom implements Exception {
  const _IoBoom();
}

/// A fake transport request whose body is an arbitrary (here, erroring) stream.
class _StreamBodyRequest implements TransportRequest {
  _StreamBodyRequest(this._body);
  final Stream<List<int>> _body;

  @override
  String get method => 'POST';
  @override
  Uri get uri => Uri.parse('/x');
  @override
  Map<String, List<String>> get headers => const {};
  @override
  Stream<List<int>> get bodyStream => _body;
  @override
  String get remoteAddress => 'test';
  @override
  Future<void> get closed => Completer<void>().future;
}
