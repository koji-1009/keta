import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

/// A minimal IOSink that records written lines, for asserting on StdoutLog.
class _CaptureSink implements IOSink {
  final StringBuffer buffer = StringBuffer();
  String get text => buffer.toString();
  @override
  void writeln([Object? obj = '']) => buffer.writeln(obj);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

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

class _FakeTransport implements Transport {
  @override
  Future<TransportServer> bind(
    int port,
    FutureOr<Response> Function(TransportRequest) onRequest,
  ) => throw UnimplementedError();
}

/// A request whose connection close can be triggered, to exercise the
/// transport `closed` → `ctx.abort()` wiring.
class _CloseableRequest implements TransportRequest {
  _CloseableRequest(this.method, this.uri, this.headers);
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final Map<String, List<String>> headers;
  @override
  final String remoteAddress = 'test';
  final Completer<void> _closed = Completer<void>();

  @override
  Stream<List<int>> get bodyStream => const Stream.empty();
  @override
  Future<void> get closed => _closed.future;
  void disconnect() => _closed.complete();
}

void main() {
  group('timeout middleware', () {
    test(
      'fires 504, completes c.aborted, and warns on late completion',
      () async {
        final env = newEnv();
        final gate = Completer<void>();
        final sawAbort = Completer<void>();
        final app = App<Env>()..use(timeout(const Duration(milliseconds: 20)));
        app.get('/slow', (c) async {
          unawaited(c.aborted.then((_) => sawAbort.complete()));
          await gate.future;
          return c.text('late');
        });
        final client = TestClient(app, env);

        final r = await client.get('/slow');
        expect(r.status, 504);
        expect(r.json(), {'error': 'request timeout'});
        await sawAbort.future.timeout(const Duration(seconds: 1));

        gate.complete();
        await pumpEventQueue();
        final lines = (env.log as MemLog).lines;
        expect(
          lines.any(
            (l) =>
                l['level'] == 'warn' &&
                l['msg'] == 'handler completed after timeout',
          ),
          isTrue,
        );
      },
    );

    test('a synchronous handler result passes through untouched', () {
      final c = testContext(newEnv());
      final result = timeout<Env>(Duration.zero)(c, (c) => c.text('sync'));
      expect(result, isA<Response>());
    });

    test('an error before the deadline propagates unchanged', () async {
      final app = App<Env>()..use(timeout(const Duration(seconds: 5)));
      app.get(
        '/boom',
        (c) async => throw const KetaException.status(418, 'teapot'),
      );
      final client = TestClient(app, newEnv());
      final r = await client.get('/boom');
      expect(r.status, 418);
    });
  });

  group('request body', () {
    test(
      'exceeding maxBodyBytes is a 413, the exact limit is allowed',
      () async {
        final under = testContext(
          newEnv(),
          method: 'POST',
          rawBody: utf8.encode('12345678'),
          maxBodyBytes: 8,
        );
        expect((await under.bodyBytes()).length, 8);

        final over = testContext(
          newEnv(),
          method: 'POST',
          rawBody: utf8.encode('123456789'),
          maxBodyBytes: 8,
        );
        await expectLater(
          over.bodyBytes(),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 413)),
        );
        // A retry must re-throw the 413, not an opaque "stream already listened"
        // StateError (which would escape as a 500).
        await expectLater(
          over.bodyBytes(),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 413)),
        );
        await expectLater(
          over.body(),
          throwsA(isA<KetaException>().having((e) => e.status, 'status', 413)),
        );
      },
    );

    test('invalid JSON is a 400, and a retry still throws', () async {
      final c = testContext(newEnv(), rawBody: utf8.encode('{not json'));
      await expectLater(
        c.body(),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
      // Caching is success-only, so a second read re-throws rather than
      // returning a stale null.
      await expectLater(c.body(), throwsA(isA<KetaException>()));
    });

    test('an empty body decodes to null and is cached', () async {
      final c = testContext(newEnv());
      expect(await c.body(), isNull);
      expect(await c.body(), isNull);
    });

    test('the decoded body and raw bytes are cached across calls', () async {
      final c = testContext(newEnv(), jsonBody: {'a': 1});
      final first = await c.body();
      expect(identical(first, await c.body()), isTrue);
      final bytes = await c.bodyBytes();
      expect(identical(bytes, await c.bodyBytes()), isTrue);
    });

    test('the body stream can be consumed only once', () async {
      final c1 = testContext(newEnv(), jsonBody: {'a': 1});
      c1.bodyStream();
      expect(() => c1.bodyStream(), throwsStateError);
      await expectLater(c1.bodyBytes(), throwsStateError);

      // Reading bytes first lets bodyStream replay the cached bytes.
      final c2 = testContext(newEnv(), jsonBody: {'a': 1});
      final bytes = await c2.bodyBytes();
      expect(await c2.bodyStream().expand((x) => x).toList(), bytes);
    });
  });

  group('c.param typing', () {
    test('parses double and bool, rejecting bad input with 400', () {
      final c = testContext(
        newEnv(),
        params: {'d': '2.5', 't': 'true', 'f': 'false', 'bad': 'TRUE'},
      );
      expect(c.param<double>('d'), 2.5);
      expect(c.param<bool>('t'), isTrue);
      expect(c.param<bool>('f'), isFalse);
      expect(
        () => c.param<bool>('bad'),
        throwsA(isA<KetaException>().having((e) => e.status, 'status', 400)),
      );
      expect(() => c.param<double>('bad'), throwsA(isA<KetaException>()));
    });

    test('an unknown name or unsupported type is an ArgumentError', () {
      final c = testContext(newEnv(), params: {'id': 'x'});
      expect(() => c.param<String>('nope'), throwsArgumentError);
      expect(() => c.param<Duration>('id'), throwsArgumentError);
    });
  });

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

  group('per-request store', () {
    test('get/set/tryGet with identity-compared keys', () {
      final c = testContext(newEnv());
      final k = Key<int>('n');
      expect(() => c.get(k), throwsStateError);
      expect(c.tryGet(k), isNull);
      c.set(k, 7);
      expect(c.get(k), 7);

      // A bound null is "present", distinct from unset.
      final kn = Key<int?>('maybe');
      c.set(kn, null);
      expect(c.get(kn), isNull);

      // Keys compare by identity: a same-named new key is a different key.
      expect(() => c.get(Key<int>('n')), throwsStateError);
    });
  });

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

  test('App.routes exposes registered routes in order with their docs', () {
    final app = App<Env>();
    app.get('/users/:id', (c) => c.text(''), doc: 'get-user');
    app
        .on(root.segments('p').capture(integer))
        .post((c, p) => c.text(''), doc: 'post-p');
    final routes = app.routes;
    expect(
      [for (final r in routes) (r.method, r.template)],
      [('GET', '/users/:id'), ('POST', '/p/:p0')],
    );
    expect(routes[0].doc, 'get-user');
    expect(routes[1].doc, 'post-p');
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

  test('an empty capture name in a pattern fails fast', () {
    final app = App<Env>();
    expect(() => app.get('/x/:', (c) => c.text('')), throwsArgumentError);
    expect(() => app.group('/:'), throwsArgumentError);
  });

  group('cors wildcard', () {
    test('answers any origin with * and custom method/header lists', () async {
      final app = App<Env>()
        ..use(
          cors(
            allowOrigins: ['*'],
            allowMethods: ['GET', 'PUT'],
            allowHeaders: ['x-custom'],
          ),
        );
      app.get('/x', (c) => c.text('ok'));
      final client = TestClient(app, newEnv());

      final r = await client.get(
        '/x',
        headers: {'origin': 'https://any.example'},
      );
      expect(r.headers['access-control-allow-origin'], '*');
      expect(r.headers['access-control-allow-methods'], 'GET, PUT');
      expect(r.headers['access-control-allow-headers'], 'x-custom');

      // The wildcard short-circuits, so even a request with no Origin is allowed.
      final noOrigin = await client.get('/x');
      expect(noOrigin.headers['access-control-allow-origin'], '*');

      final pre = await client.options('/x');
      expect(pre.status, 204);
      expect(pre.headers['access-control-allow-origin'], '*');
    });
  });

  group('tracing', () {
    test('TraceContext.parse rejects malformed headers', () {
      const malformed = [
        'garbage',
        '00-a-b-c-d',
        '00-abc-b7ad6b7169203331-01',
        '00-0af7651916cd43dd8448eb211c80319c-b7ad-01',
        '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-zz',
      ];
      for (final h in malformed) {
        expect(TraceContext.parse(h), isNull, reason: h);
      }
    });

    test('a malformed traceparent leaves traceKey unset', () async {
      final app = App<Env>()..use(tracing());
      app.get('/t', (c) => c.json({'set': c.tryGet(traceKey) != null}));
      final client = TestClient(app, newEnv());
      final r = await client.get(
        '/t',
        headers: {'traceparent': '00-short-bad-01'},
      );
      expect(r.json(), {'set': false});
    });
  });

  testBothModes('accessLog emits the error status then rethrows', (mode) async {
    final env = newEnv();
    final app = App<Env>()..use(accessLog());
    app.get(
      '/keta',
      (Context<Env> c) =>
          mode.wrap(() => throw const KetaException.status(418, 'teapot'))(),
    );
    app.get(
      '/other',
      (Context<Env> c) => mode.wrap(() => throw StateError('boom'))(),
    );
    final client = TestClient(app, env);

    expect((await client.get('/keta')).status, 418);
    expect((await client.get('/other')).status, 500);
    final lines = (env.log as MemLog).lines;
    expect(
      lines.any((l) => l['msg'] == 'request' && l['status'] == 418),
      isTrue,
    );
    expect(
      lines.any((l) => l['msg'] == 'request' && l['status'] == 500),
      isTrue,
    );
    // The rethrow reached the router's last-resort fallback.
    expect(lines.any((l) => l['msg'] == 'unhandled exception'), isTrue);
  });

  test('KetaException subtypes carry detail and hide it from toString', () {
    const e = UnprocessableEntity('invalid', ['field a']);
    expect(e.status, 422);
    expect(e.detail, ['field a']);
    expect(e.toString(), 'KetaException(422, invalid)');
    expect(const BadRequest('x').detail, isNull);
    // The arbitrary-status factory keeps its status.
    expect(const KetaException.status(418, 'teapot').status, 418);
  });

  test('Response rejects control characters in header names/values', () {
    expect(
      () => Response(200, headers: {'x-foo': ['a\r\nSet-Cookie: evil=1']}),
      throwsArgumentError,
    );
    expect(
      () => Response(200, headers: {'x-foo': ['a\nb']}),
      throwsArgumentError,
    );
    // A normal header is still accepted.
    expect(Response(200, headers: {'x-foo': ['bar']}).headers['x-foo'], ['bar']);
  });

  test('a transport disconnect (closed) fires c.aborted', () async {
    final app = App<Env>();
    final sawAbort = Completer<void>();
    app.get('/x', (c) {
      unawaited(c.aborted.then((_) => sawAbort.complete()));
      return Completer<Response>().future; // hang until cancelled
    });
    final router = app.compile(newEnv());

    final req = _CloseableRequest('GET', Uri.parse('/x'), const {});
    unawaited(Future.sync(() => router.dispatch(req))); // fire; it hangs
    await Future<void>.delayed(Duration.zero);
    req.disconnect(); // the client drops the connection

    await sawAbort.future.timeout(const Duration(seconds: 1));
  });

  test(
    'disposing a per-request log view leaves the shared timer running',
    () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final base = StdoutLog(
        sink: sink,
        flushInterval: const Duration(milliseconds: 20),
      );
      addTearDown(base.dispose);

      final view = base.withFields({'reqId': 'x'});
      (view as StdoutLog).dispose(); // must be a no-op — the timer is shared

      base.info('after-dispose');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sink.text, contains('after-dispose')); // base still auto-flushed
    },
  );
}
