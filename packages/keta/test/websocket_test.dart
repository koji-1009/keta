@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

Future<Env> boot() async => Env(StdoutLog(flushInterval: Duration.zero));

Env newEnv() => Env(StdoutLog(flushInterval: Duration.zero));

/// Runs [mw] against a fixed [response] handler and returns what it produced —
/// the single-middleware harness shape used to assert, in isolation, that a
/// middleware's rebuild carries an upgrade response's `upgrade` field through.
Future<Response> runMw(
  Middleware<Env> mw,
  Context<Env> c,
  Response response,
) async => mw(c, (_) => response);

/// An inert upgrade response: its `onConnected` is never invoked by a
/// middleware (only a realizing transport calls it), so it is safe to shuttle
/// through a rebuild and inspect.
Response upgradeResponse() => Response.upgrade((channel) {});

/// Collects [n] messages from [ws] (or whatever arrives before it closes),
/// bounded so a missing message fails the test instead of hanging it.
Future<List<Object?>> _take(WebSocket ws, int n) {
  final out = <Object?>[];
  final completer = Completer<List<Object?>>();
  late StreamSubscription<dynamic> sub;
  void finish() {
    if (!completer.isCompleted) completer.complete(out);
  }

  sub = ws.listen(
    (dynamic m) {
      out.add(m as Object?);
      if (out.length >= n) {
        unawaited(sub.cancel());
        finish();
      }
    },
    onDone: finish,
    onError: (_) => finish(),
  );
  return completer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => out,
  );
}

void main() {
  group('WebSocket upgrade over H1', () {
    test('echoes text and binary over a real socket', () async {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          // The ergonomic echo loop: it lives for the socket's whole lifetime,
          // proving the handshake request does not stay "in flight".
          channel.messages.listen(channel.send);
        }),
      );
      final server = await app.serve(boot, port: 8130);

      final ws = await WebSocket.connect('ws://127.0.0.1:8130/ws');
      final got = _take(ws, 2);
      ws.add('a text frame');
      ws.add([1, 2, 3, 4]);
      final msgs = await got;
      expect(msgs[0], 'a text frame');
      expect(msgs[1], equals([1, 2, 3, 4]));

      await ws.close();
      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('a server-initiated close reaches the client with its code', () async {
      final app = App<Env>();
      app.get(
        '/bye',
        (c) => Response.upgrade((channel) {
          channel.send('closing');
          channel.close(4000, 'server done');
        }),
      );
      final server = await app.serve(boot, port: 8131);

      final ws = await WebSocket.connect('ws://127.0.0.1:8131/bye');
      // One subscription only (a WebSocket is single-subscription): collect
      // messages and wait for the close frame in the same listen.
      final msgs = <Object?>[];
      final closed = Completer<void>();
      ws.listen(
        (dynamic m) => msgs.add(m as Object?),
        onDone: () => closed.complete(),
      );
      await closed.future.timeout(const Duration(seconds: 5));
      expect(msgs, ['closing']);
      expect(ws.closeCode, 4000);
      await ws.close();

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('a client disconnect completes the handler channel done', () async {
      final handlerDone = Completer<void>();
      final app = App<Env>();
      app.get(
        '/watch',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {});
          channel.done.then((_) {
            if (!handlerDone.isCompleted) handlerDone.complete();
          });
        }),
      );
      final server = await app.serve(boot, port: 8132);

      final ws = await WebSocket.connect('ws://127.0.0.1:8132/watch');
      await ws.close();

      await handlerDone.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('channel.done did not fire on client disconnect'),
      );
      expect(handlerDone.isCompleted, isTrue);

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('a non-upgrade request to an upgrade route gets 426', () async {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) => channel.close()),
      );
      final server = await app.serve(boot, port: 8133);

      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:8133/ws'),
      );
      final response = await request.close();
      expect(response.statusCode, 426); // Upgrade Required
      expect(response.headers.value('upgrade'), 'websocket');
      await response.drain<void>();
      client.close();

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('security middleware gates the upgrade: 401 vs switch', () async {
      // A stand-in for keta_openapi's `enforceSecurity` — the same shape: a
      // Middleware that raises Unauthorized (→ 401) before `next`, so the
      // upgrade Response is never even built. This is the whole point of
      // modelling upgrade as a returned value: the security gate composes in
      // front of it exactly as it does for any response.
      Middleware<Env> requireToken() => (c, next) {
        if (c.header('authorization') != 'Bearer ok') {
          throw const Unauthorized('authentication required');
        }
        return next(c);
      };
      final app = App<Env>()..use(requireToken());
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen(channel.send);
        }),
      );
      final server = await app.serve(boot, port: 8134);

      // No credential → the handshake is refused (server answered 401, not 101),
      // so the client's upgrade attempt fails rather than connecting.
      await expectLater(
        WebSocket.connect('ws://127.0.0.1:8134/ws'),
        throwsA(isA<WebSocketException>()),
      );

      // A valid credential → the upgrade proceeds and the echo works.
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:8134/ws',
        headers: {'authorization': 'Bearer ok'},
      );
      final got = _take(ws, 1);
      ws.add('through');
      expect((await got).first, 'through');
      await ws.close();

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('shutdown with an open socket completes within grace + margin',
        () async {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {}); // idle, never closes on its own
        }),
      );
      final server = await app.serve(boot, port: 8135);

      final ws = await WebSocket.connect('ws://127.0.0.1:8135/ws');
      // The socket is idle and open. Shutdown must force it closed rather than
      // wait on it forever.
      final watch = Stopwatch()..start();
      await server.shutdown(grace: const Duration(milliseconds: 500));
      watch.stop();
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'an open socket must not hang shutdown',
      );
      // The client observes the going-away close.
      await ws.drain<void>().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      expect(ws.closeCode, isNotNull);
      await ws.close();
    });
  });

  group('TestClient in-process upgrade', () {
    test('connect upgrades and round-trips through the handler channel',
        () async {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((m) => channel.send('echo:$m'));
        }),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect('/ws');
      expect(up.upgraded, isTrue);
      final got = <Object>[];
      up.socket!.messages.listen(got.add);
      up.socket!.send('one');
      up.socket!.send('two');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got, ['echo:one', 'echo:two']);

      await up.socket!.close();
      await up.socket!.done.timeout(const Duration(seconds: 1));
    });

    test('connect surfaces a middleware rejection instead of upgrading',
        () async {
      Middleware<Env> requireToken() => (c, next) {
        if (c.header('authorization') != 'Bearer ok') {
          throw const Unauthorized('authentication required');
        }
        return next(c);
      };
      final app = App<Env>()..use(requireToken());
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) => channel.close()),
      );
      final client = TestClient(app, await boot());

      final rejected = await client.connect('/ws');
      expect(rejected.upgraded, isFalse);
      expect(rejected.rejection!.status, 401);

      final ok = await client.connect(
        '/ws',
        headers: {'authorization': 'Bearer ok'},
      );
      expect(ok.upgraded, isTrue);
      await ok.socket!.close();
    });

    test('a client-side close completes the handler channel done', () async {
      final handlerDone = Completer<void>();
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.done.then((_) {
            if (!handlerDone.isCompleted) handlerDone.complete();
          });
        }),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect('/ws');
      await up.socket!.close();
      await handlerDone.future.timeout(const Duration(seconds: 1));
      expect(handlerDone.isCompleted, isTrue);
    });
  });

  group('an upgrade response survives a middleware rebuild', () {
    test('Response.copyWith carries the upgrade field by default', () {
      final up = upgradeResponse();
      final copy = up.copyWith(
        headers: {
          'x-test': const ['1'],
        },
      );
      expect(copy.upgrade, same(up.upgrade));
      expect(copy.status, 101);
      expect(copy.body, '');
      expect(copy.headers['x-test'], ['1']);
    });

    test('copyWith re-runs the 101/empty-body guard, so it stays intact', () {
      final up = upgradeResponse();
      // Handing an upgrade response a body must throw at construction — the
      // copy path is not a way around the invariant.
      expect(() => up.copyWith(body: 'boom'), throwsArgumentError);
      expect(() => up.copyWith(status: 200), throwsArgumentError);
      // And the constructor guard itself is unchanged: a non-101 or non-empty
      // upgrade never constructs.
      expect(
        () => Response(200, upgrade: Upgrade((_) {})),
        throwsArgumentError,
      );
      expect(
        () => Response(101, upgrade: Upgrade((_) {}), body: 'x'),
        throwsArgumentError,
      );
    });

    test('cors actual-response path preserves upgrade (and merges headers)',
        () async {
      final r = await runMw(
        cors(allowOrigins: const ['*']),
        testContext(newEnv(), headers: {'origin': 'https://example.test'}),
        upgradeResponse(),
      );
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
      expect(r.body, '');
      expect(r.headers['access-control-allow-origin'], ['*']);
    });

    test('cors preflight is answered independently, untouched by upgrade',
        () async {
      // A preflight never reaches the handler, so there is no upgrade to carry;
      // this pins that our change left the preflight branch (a fresh 204) alone.
      final r = await runMw(
        cors(allowOrigins: const ['*']),
        testContext(
          newEnv(),
          method: 'OPTIONS',
          headers: {
            'origin': 'https://example.test',
            'access-control-request-method': 'GET',
          },
        ),
        // The next handler is never invoked on the preflight path.
        upgradeResponse(),
      );
      expect(r.status, 204);
      expect(r.upgrade, isNull);
    });

    test('etag passes an upgrade through untouched (no tag, no 304)', () async {
      final r = await runMw(
        etag(),
        testContext(newEnv()),
        upgradeResponse(),
      );
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
      expect(r.headers.containsKey('etag'), isFalse);
    });

    test('gzip passes an upgrade through untouched (no Vary, no encoding)',
        () async {
      final r = await runMw(
        gzip(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        upgradeResponse(),
      );
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
      expect(r.headers.containsKey('content-encoding'), isFalse);
      expect(r.headers.containsKey('vary'), isFalse);
    });

    test('accessLog passes an upgrade through untouched', () async {
      final r = await runMw(
        accessLog(),
        testContext(newEnv()),
        upgradeResponse(),
      );
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
    });

    test('the composed chain (accessLog→cors→gzip→etag) preserves upgrade',
        () async {
      final r = await runMw(
        accessLog(),
        testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
        await runMw(
          cors(allowOrigins: const ['*']),
          testContext(
            newEnv(),
            headers: {'accept-encoding': 'gzip'},
          ),
          await runMw(
            gzip(),
            testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
            await runMw(
              etag(),
              testContext(newEnv()),
              upgradeResponse(),
            ),
          ),
        ),
      );
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
    });

    test('TestClient.connect upgrades through the full middleware chain',
        () async {
      // The end-to-end proof: behind cors + gzip + etag + accessLog, a real
      // handshake must actually switch and round-trip — not answer 101 and
      // silently fail to upgrade (the reported defect).
      final app = App<Env>()
        ..use(accessLog())
        ..use(cors(allowOrigins: const ['*']))
        ..use(gzip())
        ..use(etag());
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((m) => channel.send('echo:$m'));
        }),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect(
        '/ws',
        headers: {'accept-encoding': 'gzip', 'origin': 'https://example.test'},
      );
      expect(
        up.upgraded,
        isTrue,
        reason: 'the upgrade must survive the full middleware chain',
      );
      final got = <Object>[];
      up.socket!.messages.listen(got.add);
      up.socket!.send('one');
      up.socket!.send('two');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(got, ['echo:one', 'echo:two']);

      await up.socket!.close();
      await up.socket!.done.timeout(const Duration(seconds: 1));
    });
  });
}
