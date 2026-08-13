/// Owns multi-isolate serve(): running N listeners behind one port and shutting
/// them all down, and tearing worker 0 back down when a later worker's spawn
/// fails so no socket or env is leaked.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:keta/keta.dart';
import 'package:test/test.dart';

class IsoEnv(@override final Log log) implements HasLog, Disposable {
  @override
  Future<void> close() async {}
}

// Top-level so it is sendable to spawned isolates. Runs once per isolate.
Future<IsoEnv> bootIso() async =>
    IsoEnv(StdoutLog(flushInterval: Duration.zero));

App<IsoEnv> buildIsoApp() {
  final app = App<IsoEnv>()..use(recover());
  app.get('/ping', (c) => c.json({'pong': true}));
  return app;
}

void main() {
  test(
    'serve(isolates: n) runs multiple listeners and shuts them all down',
    () async {
      final server = await buildIsoApp().serve(
        bootIso,
        isolates: 3,
        port: 8092,
      );

      final client = HttpClient();
      for (var i = 0; i < 6; i++) {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:8092/ping'),
        );
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        expect(resp.statusCode, 200);
        expect(jsonDecode(body), {'pong': true});
      }
      client.close();

      await server.shutdown(grace: const Duration(seconds: 1));

      // After shutdown the port is free again; a connection now fails.
      final client2 = HttpClient();
      await expectLater(
        client2
            .getUrl(Uri.parse('http://127.0.0.1:8092/ping'))
            .then((r) => r.close()),
        throwsA(isA<SocketException>()),
      );
      client2.close();
    },
  );

  test('a failed worker spawn tears down worker 0 (no leaked socket/env)', () async {
    const port = 8096;
    // Capturing a ReceivePort makes this boot non-sendable, so worker 0 boots
    // on this isolate but spawning worker 1 fails.
    final trap = ReceivePort();
    Future<IsoEnv> unsendableBoot() async {
      trap.sendPort; // captured -> closure is not sendable across isolates
      return IsoEnv(StdoutLog(flushInterval: Duration.zero));
    }

    await expectLater(
      buildIsoApp().serve(unsendableBoot, isolates: 2, port: port),
      throwsA(isA<StateError>()),
    );
    trap.close();

    // Worker 0's listener must have been torn down: the port is bindable again.
    final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    await probe.close();
  });

  group('transportFactory', () {
    test('a configured transport reaches every worker', () async {
      // The claim this makes true: `H1Transport`'s doc says a TLS listener
      // shares the accept queue across `serve(isolates: n)` "exactly as the
      // plaintext one does". It does — but `transport:` was the only way to
      // supply one and `isolates > 1` rejected it outright, so neither TLS nor
      // idleTimeout could be configured in a multi-isolate server at all.
      final server = await buildIsoApp().serve(
        bootIso,
        isolates: 3,
        port: 8098,
        transportFactory: boundedTransport,
      );
      addTearDown(() => server.shutdown(grace: const Duration(seconds: 1)));

      final client = HttpClient();
      addTearDown(client.close);
      // Every worker shares the accept queue, so several requests land across
      // the isolates that each built their own transport from the factory.
      for (var i = 0; i < 6; i++) {
        final resp = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:8098/ping'),
        )).close();
        expect(resp.statusCode, 200);
        await resp.drain<void>();
      }
    });

    test('an instance and a factory together is an authoring defect', () {
      expect(
        buildIsoApp().serve(
          bootIso,
          port: 8099,
          transport: const H1Transport(),
          transportFactory: boundedTransport,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an instance with isolates > 1 still says why, and what to use', () {
      expect(
        buildIsoApp().serve(
          bootIso,
          isolates: 2,
          port: 8100,
          transport: const H1Transport(),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('transportFactory'),
          ),
        ),
      );
    });
  });

  test('a worker that dies after binding is reported, and shutdown does not '
      'wait for it', () async {
    // The spec lists worker-isolate death as a required chaos scenario and it
    // had no test. The old code closed the `errors` port in the `finally` right
    // after a successful spawn, so nothing was listening when a worker later
    // died: with a `shared: true` listener the corpse simply left the accept
    // set, the process kept serving on one fewer isolate with nothing logged,
    // and shutdown then sent to a dead control port and waited out the entire
    // `grace + 5s` for an ack that could never come.
    deaths.clear();
    parentIsolate = true;
    final server = await buildIsoApp().serve(
      bootThatCrashesWorkers,
      isolates: 2,
      port: 8097,
    );
    // `bootThatCrashesWorkers` arms a timer in the spawned isolate only; worker
    // 0 boots here and stays healthy, which is what keeps this test's own
    // process alive to observe the death.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(deaths, hasLength(1));

    final watch = Stopwatch()..start();
    await server.shutdown(grace: const Duration(seconds: 2));
    watch.stop();
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'a dead worker must not be waited on',
    );
  });
}

/// A transport built per isolate, carrying a knob that only a configured
/// transport can hold. `H1Transport` has had `idleTimeout` since it was
/// introduced, but the only way to pass one was `transport:`, which
/// `isolates > 1` refused — so the knob that bounds a slow-header hold was
/// unreachable in exactly the configuration a real deployment runs. Top-level
/// so it is sendable; the factory, not an instance, is what crosses.
Transport boundedTransport() =>
    const H1Transport(idleTimeout: Duration(seconds: 5));

/// Death reports observed by the parent isolate. A worker gets its own copy of
/// this library's statics, so only the parent's entries land here — which is
/// exactly the isolate whose log is supposed to carry the report.
final deaths = <String>[];

/// Set by the test before serving. A spawned isolate initializes this library
/// afresh, so it reads `false` there and `true` here — the discriminator that
/// lets one boot function be healthy in the parent and fatal in a worker.
/// (`Isolate.current.debugName` cannot do this job: package:test already runs
/// the test body in a spawned isolate of its own.)
var parentIsolate = false;

/// Boots normally on the parent isolate and arms a fatal async error on any
/// spawned one, so the worker dies AFTER it has bound and been handed back.
Future<IsoEnv> bootThatCrashesWorkers() async {
  if (!parentIsolate) {
    Timer(
      const Duration(milliseconds: 200),
      // Uncaught, in the root zone, with `errorsAreFatal: true`: the isolate
      // dies exactly as it would on any unhandled error in worker code.
      () => throw StateError('worker crash'),
    );
  }
  return IsoEnv(_DeathRecordingLog());
}

class _DeathRecordingLog implements Log {
  final _out = StdoutLog(flushInterval: Duration.zero);

  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) {
    if (msg.startsWith('worker isolate died')) deaths.add(msg);
  }

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _out.debug(msg, fields);
  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _out.info(msg, fields);
  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _out.warn(msg, fields);
  @override
  Future<void> flush() => _out.flush();
  @override
  Log withFields(Map<String, Object?> fields) => this;
}
