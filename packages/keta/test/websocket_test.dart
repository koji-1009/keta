/// Owns WebSocket upgrade end-to-end over H1 and in-process TestClient: the
/// handshake and echo/close lifecycle, the security gate and 426 refusals,
/// graceful shutdown of open sockets, the watch-only drop-not-buffer channel,
/// an upgrade response surviving a middleware rebuild, and the maxIdle/
/// maxLifetime lifetime bounds (construction validation, firing on a real
/// socket, and the expiry-vs-client-close race).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/src/h1_transport.dart' show debugWebSocketChannel;
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// An inert upgrade response: its `onConnected` is never invoked by a
/// middleware (only a realizing transport calls it), so it is safe to shuttle
/// through a rebuild and inspect.
Response upgradeResponse() => Response.upgrade((channel) {});

/// A minimal in-memory `dart:io` [WebSocket] stand-in for unit-testing the
/// channel adapter's inbound path in isolation: [emit] pushes a frame, and
/// [peerClose] ends the stream (a peer-initiated close). Every other WebSocket
/// member routes through `noSuchMethod` — the adapter's inbound behavior needs
/// only `listen` and the stream's end.
class _FakeInboundWebSocket extends Stream<dynamic> implements WebSocket {
  final StreamController<dynamic> _frames = StreamController<dynamic>();

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _frames.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  void emit(dynamic frame) => _frames.add(frame);

  /// Ends the raw stream — a peer-initiated close, the case that must still
  /// drive the channel's `done` even with no `messages` subscriber.
  Future<void> peerClose() => _frames.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
      app.get('/ws', (c) => Response.upgrade((channel) => channel.close()));
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
      // A stand-in for `enforceSecurity` — the same shape: a
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

    test(
      'shutdown with an open socket completes within grace + margin',
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
      },
    );
  });

  group('watch-only channel does not buffer without bound (item 1)', () {
    test('a push-only flood is dropped, not buffered, and done still fires on '
        'peer close', () async {
      // The unit-level proof, deterministic: drive the channel adapter's
      // inbound path directly with a fake socket, never subscribing to
      // `messages` (a server-push-only handler). Every frame must be
      // discarded — never accumulated in the controller — and the peer close
      // must still complete `done` despite there being no listener.
      final fake = _FakeInboundWebSocket();
      final (channel, dropped) = debugWebSocketChannel(fake);
      // Never listen to `channel.messages`. Flood the raw socket.
      const n = 100000;
      for (var i = 0; i < n; i++) {
        fake.emit('frame $i');
      }
      // Peer closes: all buffered raw frames deliver (and are dropped), then
      // `onDone` fires → `done` completes and the drop tally is final.
      await fake.peerClose();
      await channel.done.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('done did not fire on peer close for a push-only channel'),
      );
      // Every frame was discarded: nothing was buffered in `_incoming`, so
      // memory stayed bounded regardless of the flood size.
      expect(dropped(), n);
    });

    test('SMOKE: a push-only handler survives a real peer flood and its done '
        'fires on close', () async {
      // A liveness smoke test, not the drop pin. Over a real socket a handler
      // that never reads `channel.messages` takes a peer flood and then a
      // close, and we only observe that the handler stays alive and its `done`
      // fires. The drop-not-buffer behavior itself is unobservable end-to-end
      // (the transport builds the channel internally and exposes no drop
      // tally on this path), so it is pinned deterministically by the unit
      // test above via `debugWebSocketChannel`. This one guards against the
      // flood wedging or crashing the served handler; it would pass even if
      // frames were buffered, which is exactly why it is labelled a smoke
      // test rather than the contract.
      final handlerDone = Completer<void>();
      final app = App<Env>();
      app.get(
        '/push',
        (c) => Response.upgrade((channel) {
          // Server-push-only: never subscribe to inbound frames, just observe
          // the disconnect.
          channel.done.then((_) {
            if (!handlerDone.isCompleted) handlerDone.complete();
          });
        }),
      );
      final server = await app.serve(boot, port: 8136);

      final ws = await WebSocket.connect('ws://127.0.0.1:8136/push');
      for (var i = 0; i < 100000; i++) {
        ws.add('x');
      }
      await ws.close();

      await handlerDone.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () =>
            fail('done did not fire on peer close for a push-only handler'),
      );
      expect(handlerDone.isCompleted, isTrue);

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });
  });

  group('TestClient in-process upgrade', () {
    test(
      'connect upgrades and round-trips through the handler channel',
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
      },
    );

    test(
      'connect surfaces a middleware rejection instead of upgrading',
      () async {
        Middleware<Env> requireToken() => (c, next) {
          if (c.header('authorization') != 'Bearer ok') {
            throw const Unauthorized('authentication required');
          }
          return next(c);
        };
        final app = App<Env>()..use(requireToken());
        app.get('/ws', (c) => Response.upgrade((channel) => channel.close()));
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
      },
    );

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

    test(
      'cors actual-response path preserves upgrade (and merges headers)',
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
      },
    );

    test(
      'cors preflight is answered independently, untouched by upgrade',
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
      },
    );

    test('etag passes an upgrade through untouched (no tag, no 304)', () async {
      final r = await runMw(etag(), testContext(newEnv()), upgradeResponse());
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
      expect(r.headers.containsKey('etag'), isFalse);
    });

    test(
      'gzip passes an upgrade through untouched (no Vary, no encoding)',
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
      },
    );

    test('accessLog passes an upgrade through untouched', () async {
      final r = await runMw(
        accessLog(),
        testContext(newEnv()),
        upgradeResponse(),
      );
      expect(r.upgrade, isNotNull);
      expect(r.status, 101);
    });

    test(
      'the composed chain (accessLog→cors→gzip→etag) preserves upgrade',
      () async {
        final r = await runMw(
          accessLog(),
          testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
          await runMw(
            cors(allowOrigins: const ['*']),
            testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
            await runMw(
              gzip(),
              testContext(newEnv(), headers: {'accept-encoding': 'gzip'}),
              await runMw(etag(), testContext(newEnv()), upgradeResponse()),
            ),
          ),
        );
        expect(r.upgrade, isNotNull);
        expect(r.status, 101);
      },
    );

    test(
      'TestClient.connect upgrades through the full middleware chain',
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
          headers: {
            'accept-encoding': 'gzip',
            'origin': 'https://example.test',
          },
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
      },
    );
  });

  group('lifetime bounds (E-21a)', () {
    test('maxIdle and maxLifetime reject non-positive durations', () {
      expect(
        () => Response.upgrade((_) {}, maxIdle: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () =>
            Response.upgrade((_) {}, maxIdle: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => Response.upgrade((_) {}, maxLifetime: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => Response.upgrade(
          (_) {},
          maxLifetime: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('without maxIdle/maxLifetime a silent connection stays open '
        '(defaults-off, unchanged behavior)', () async {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {});
        }),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect('/ws');
      var doneFired = false;
      unawaited(up.socket!.done.then((_) => doneFired = true));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        doneFired,
        isFalse,
        reason: 'no bound was set, so silence alone must never end it',
      );

      await up.socket!.close();
    });

    test('sending frames alone does not reset maxIdle — only inbound traffic '
        'proves the peer is alive', () async {
      Timer? pusher;
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          // Never reads `channel.messages`, only ever sends. If `send()`
          // reset the idle clock, this would never expire.
          pusher = Timer.periodic(
            const Duration(milliseconds: 5),
            (_) => channel.send('x'),
          );
        }, maxIdle: const Duration(milliseconds: 30)),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect('/ws');
      up.socket!.messages.listen((_) {}); // drain, doesn't matter to maxIdle
      await up.socket!.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            fail('maxIdle did not fire despite only outbound traffic'),
      );
      pusher?.cancel();
    });

    test(
      'inbound frames reset maxIdle: an actively-communicating peer is never '
      'reaped',
      () async {
        final app = App<Env>();
        app.get(
          '/ws',
          (c) => Response.upgrade((channel) {
            // Must listen for an inbound frame to count as a reset — a
            // frame that would be dropped (no subscriber) cannot prove
            // liveness to a handler that never sees it.
            channel.messages.listen((_) {});
          }, maxIdle: const Duration(milliseconds: 40)),
        );
        final client = TestClient(app, await boot());

        final up = await client.connect('/ws');
        var n = 0;
        final pinger = Timer.periodic(const Duration(milliseconds: 10), (_) {
          up.socket!.send('ping ${n++}');
        });
        var doneFired = false;
        unawaited(up.socket!.done.then((_) => doneFired = true));

        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          doneFired,
          isFalse,
          reason: 'continuous inbound frames must keep resetting maxIdle',
        );
        expect(n, greaterThan(1));

        pinger.cancel();
        await up.socket!.close();
      },
    );

    test('maxLifetime fires despite continuous inbound activity', () async {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {});
        }, maxLifetime: const Duration(milliseconds: 60)),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect('/ws');
      var n = 0;
      final pinger = Timer.periodic(const Duration(milliseconds: 10), (_) {
        up.socket!.send('ping ${n++}');
      });

      await up.socket!.done.timeout(
        const Duration(seconds: 2),
        onTimeout: () =>
            fail('maxLifetime did not fire despite continuous activity'),
      );
      expect(
        n,
        greaterThan(1),
        reason: 'inbound frames were still flowing when the cap fired',
      );
      pinger.cancel();
    });

    test('idle expiry closes a real socket with WebSocket close code 1001 '
        '(Going Away)', () async {
      final app = App<Env>();
      app.get(
        '/idle-ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {});
        }, maxIdle: const Duration(milliseconds: 60)),
      );
      final server = await app.serve(boot, port: 8140);

      final ws = await WebSocket.connect('ws://127.0.0.1:8140/idle-ws');
      final closed = Completer<void>();
      ws.listen((_) {}, onDone: () => closed.complete());
      await closed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('idle expiry never closed the real socket'),
      );
      expect(ws.closeCode, 1001);

      await ws.close();
      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('lifetime expiry closes a real socket with WebSocket close code 1001 '
        '(Going Away), despite continuous inbound traffic', () async {
      final app = App<Env>();
      app.get(
        '/life-ws',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {});
        }, maxLifetime: const Duration(milliseconds: 60)),
      );
      final server = await app.serve(boot, port: 8141);

      final ws = await WebSocket.connect('ws://127.0.0.1:8141/life-ws');
      final pinger = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => ws.add('ping'),
      );
      final closed = Completer<void>();
      ws.listen((_) {}, onDone: () => closed.complete());
      await closed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('lifetime expiry never closed the real socket'),
      );
      pinger.cancel();
      expect(ws.closeCode, 1001);

      await ws.close();
      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test(
      'no double teardown when an idle expiry races a client-initiated close',
      () async {
        final handlerDone = Completer<void>();
        final app = App<Env>();
        app.get(
          '/race-ws',
          (c) => Response.upgrade((channel) {
            channel.messages.listen((_) {});
            channel.done.then((_) {
              if (!handlerDone.isCompleted) handlerDone.complete();
            });
          }, maxIdle: const Duration(milliseconds: 30)),
        );
        final client = TestClient(app, await boot());

        final up = await client.connect('/race-ws');
        // Close from the client right around when maxIdle is also due to
        // fire — a race between the two teardown triggers.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await up.socket!.close();

        await handlerDone.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('channel.done never fired after the race'),
        );
        expect(handlerDone.isCompleted, isTrue);
      },
    );

    test('no double teardown when a lifetime expiry races a client-initiated '
        'close', () async {
      final handlerDone = Completer<void>();
      final app = App<Env>();
      app.get(
        '/race-ws-life',
        (c) => Response.upgrade((channel) {
          channel.messages.listen((_) {});
          channel.done.then((_) {
            if (!handlerDone.isCompleted) handlerDone.complete();
          });
        }, maxLifetime: const Duration(milliseconds: 30)),
      );
      final client = TestClient(app, await boot());

      final up = await client.connect('/race-ws-life');
      // Close from the client right around when maxLifetime is also due to
      // fire — a race between the two teardown triggers.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await up.socket!.close();

      await handlerDone.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('channel.done never fired after the race'),
      );
      expect(handlerDone.isCompleted, isTrue);
    });
  });
}
