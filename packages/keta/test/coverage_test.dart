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

const _overflowMsg = 'log backlog overflowed, oldest lines dropped';

/// A sink that refuses, the way a broken pipe or a full disk does.
class _BrokenSink extends _CaptureSink {
  bool broken = true;
  @override
  Future<void> flush() async {
    if (broken) throw const SocketException('broken pipe');
  }
}

/// A [_CaptureSink] that also notices whether two flushes are ever in flight at
/// once, and takes long enough to flush that an overlap has room to happen.
class _ConcurrencyCountingSink extends _CaptureSink {
  int _inFlight = 0;
  int peakConcurrentFlushes = 0;

  @override
  Future<void> flush() async {
    _inFlight++;
    if (_inFlight > peakConcurrentFlushes) peakConcurrentFlushes = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _inFlight--;
  }
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
      () => Response(
        200,
        headers: {
          'x-foo': ['a\r\nSet-Cookie: evil=1'],
        },
      ),
      throwsArgumentError,
    );
    expect(
      () => Response(
        200,
        headers: {
          'x-foo': ['a\nb'],
        },
      ),
      throwsArgumentError,
    );
    // A normal header is still accepted.
    expect(
      Response(
        200,
        headers: {
          'x-foo': ['bar'],
        },
      ).headers['x-foo'],
      ['bar'],
    );
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

  group('recover and the detail an exception carries', () {
    test('a declared status is not logged as an incident', () async {
      final env = newEnv();
      final app = App<Env>()
        ..use(recover())
        ..get('/x', (c) => throw const NotFound('nope'));
      final r = await TestClient(app, env).get('/x');
      expect(r.status, 404);
      // An expected outcome is not an incident. Logging every 404 would bury
      // the ones that matter.
      expect((env.log as MemLog).lines, isEmpty);
    });

    test('a detail reaches the operator and not the client', () async {
      final env = newEnv();
      final app = App<Env>()
        ..use(recover())
        ..get(
          '/x',
          (c) => throw const Conflict('row already exists', 'users.email'),
        );
      final r = await TestClient(app, env).get('/x');

      // The client is told the status and nothing that leaks the schema.
      expect(r.status, 409);
      expect(r.json(), {'error': 'row already exists'});
      expect(r.text(), isNot(contains('users.email')));
      // The operator is told which constraint collided. detail exists for
      // exactly this; if nothing read it, an adapter translating a driver error
      // would silently take the diagnosis with it.
      final line = (env.log as MemLog).lines.single;
      expect(line['level'], 'warn');
      expect(line['detail'], 'users.email');
      expect(line['status'], 409);
    });
  });

  group('the backlog is bounded', () {
    // A sink that stops accepting must not be able to grow the backlog without
    // limit. Nothing here asserts on timing: the bound is a property of the
    // buffer, and it is asserted as one.

    test('an unstalled sink drops nothing', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final log = StdoutLog(sink: sink, flushInterval: Duration.zero);
      for (var i = 0; i < 500; i++) {
        log.info('line-$i');
      }
      await log.flush();
      expect(sink.text, isNot(contains('overflowed')));
      expect('\n'.allMatches(sink.text.trim()).length + 1, 500);
    });

    test('past the bound the oldest go, and the newest survive', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      // Room for a handful of lines, so the overflow is exact rather than
      // approximate.
      final log = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      for (var i = 0; i < 200; i++) {
        log.info('line-$i');
      }
      await log.flush();
      // The most recent line is the one worth keeping when a sink has stalled.
      expect(sink.text, contains('line-199'));
      expect(sink.text, isNot(contains('"msg":"line-0"')));
    });

    test('what was dropped is reported, not silently swallowed', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final log = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      for (var i = 0; i < 200; i++) {
        log.info('line-$i');
      }
      await log.flush();

      final lines = const LineSplitter()
          .convert(sink.text)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      final report = lines.firstWhere((l) => l['msg'] == _overflowMsg);
      expect(report['level'], 'warn');
      // Conservation, not just "some number": every line either arrived or was
      // counted. `greaterThan(0)` would hold just as well if the counter
      // double-incremented or slipped outside the eviction loop.
      final survived = lines.where((l) => l['msg'] != _overflowMsg).length;
      expect(survived + (report['dropped']! as int), 200);
    });

    test(
      'a line larger than the whole budget does not evict the rest',
      () async {
        // The oversized line is an error's stack trace far more often than not,
        // and the lines it would evict are the ones explaining how that error
        // was reached. Dropping the giant loses one line; admitting it loses all
        // the context and overshoots the bound anyway.
        final sink = _CaptureSink();
        addTearDown(sink.close);
        final log = StdoutLog(
          sink: sink,
          flushInterval: Duration.zero,
          maxBufferedBytes: 4000,
        );
        for (var i = 0; i < 20; i++) {
          log.info('keep-$i');
        }
        log.error('boom', StateError('x'), StackTrace.fromString('T' * 8000));
        await log.flush();

        for (var i = 0; i < 20; i++) {
          expect(sink.text, contains('keep-$i'));
        }
        final report = const LineSplitter()
            .convert(sink.text)
            .map((l) => jsonDecode(l) as Map<String, Object?>)
            .firstWhere((l) => l['msg'] == _overflowMsg);
        expect(report['dropped'], 1); // the giant, and only the giant
      },
    );

    test('the count resets once reported, and does not double-count', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final log = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      for (var i = 0; i < 200; i++) {
        log.info('line-$i');
      }
      await log.flush();
      sink.buffer.clear();

      // A quiet period after the overflow must not re-report the old loss.
      log.info('calm');
      await log.flush();
      expect(sink.text, contains('calm'));
      expect(sink.text, isNot(contains('overflowed')));
    });

    test('a view flushing mid-drain neither overlaps nor reorders', () async {
      // The drain yields between slices, and c.log is a view with its own
      // handle on flush(). If the serialization lived on the instance rather
      // than on the shared backlog, a view's flush would slot into one of those
      // yields: measured, the first view line landed at index 32 -- exactly one
      // slice in -- while base lines carried on after it. Interleaved lines are
      // worse than late ones, because the timestamps stop telling the truth
      // about order.
      final sink = _ConcurrencyCountingSink();
      addTearDown(sink.close);
      final base = StdoutLog(sink: sink, flushInterval: Duration.zero);
      final view = base.withFields({'reqId': 'r1'});

      for (var i = 0; i < 1000; i++) {
        base.info('BASE-$i');
      }
      final baseFlush = base.flush(); // snapshots, writes a slice, yields
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 1000; i++) {
        view.info('VIEW-$i');
      }
      await Future.wait([baseFlush, view.flush()]);

      final msgs = const LineSplitter()
          .convert(sink.text)
          .map((l) => (jsonDecode(l) as Map<String, Object?>)['msg']! as String)
          .toList();
      final firstView = msgs.indexWhere((m) => m.startsWith('VIEW'));
      final lastBase = msgs.lastIndexWhere((m) => m.startsWith('BASE'));
      expect(
        lastBase,
        lessThan(firstView),
        reason: 'every BASE line was enqueued before any VIEW line existed',
      );
      expect(
        sink.peakConcurrentFlushes,
        1,
        reason: 'overlapping IOSink.flush() is what the chain must prevent',
      );
    });

    test('a refusing sink does not make flush() the caller problem', () async {
      // Every shutdown path is `await log.flush(); dispose();`. If flush()
      // rejected, dispose() would be skipped, the periodic timer would survive,
      // and the isolate would never exit — the process hanging because logging
      // failed. Awaiting must simply complete.
      final sink = _BrokenSink();
      addTearDown(sink.close);
      final log = StdoutLog(sink: sink, flushInterval: Duration.zero);
      log.info('x');
      await expectLater(log.flush(), completes);
    });

    test(
      'a failed drain carries its gap forward instead of erasing it',
      () async {
        final sink = _BrokenSink();
        addTearDown(sink.close);
        final log = StdoutLog(
          sink: sink,
          flushInterval: Duration.zero,
          maxBufferedBytes: 400,
        );
        for (var i = 0; i < 200; i++) {
          log.info('line-$i');
        }
        await log.flush(); // rejects internally: nothing was delivered
        sink.buffer.clear();

        // The sink comes back. The gap from the failed drain must still be
        // reported -- zeroing the counter on a drain that never landed is how a
        // gap goes silent, which is the one thing the bound exists to prevent.
        sink.broken = false;
        log.info('after-recovery');
        await log.flush();
        final report = const LineSplitter()
            .convert(sink.text)
            .map((l) => jsonDecode(l) as Map<String, Object?>)
            .firstWhere((l) => l['msg'] == _overflowMsg);
        // The evicted lines AND the batch the broken sink swallowed.
        expect(report['dropped'], 200);
      },
    );

    test('a view shares the backlog, so its lines are bounded too', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final base = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      final view = base.withFields({'reqId': 'r1'});
      for (var i = 0; i < 200; i++) {
        view.info('line-$i');
      }
      // Flushing through the base must see what the view enqueued, and must
      // account for what the view's overflow dropped.
      await base.flush();
      expect(sink.text, contains('overflowed'));
      expect(sink.text, contains('r1'));
    });
  });
}
