/// Owns single-process serve(): binding a real socket, dispatching one live
/// request end-to-end, and disposing the environment on graceful shutdown.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:test/test.dart';

class Env implements HasLog, Disposable {
  Env(this.log);
  @override
  final Log log;
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  test(
    'serve binds a real socket, handles a request, shuts down gracefully',
    () async {
      final env = Env(StdoutLog(flushInterval: Duration.zero));
      final app = App<Env>()..use(recover());
      app.get('/hello/:who', (c) => c.json({'hello': c.param<String>('who')}));

      final server = await app.serve(() async => env, port: 8091);

      final client = HttpClient();
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:8091/hello/keta'),
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      expect(resp.statusCode, 200);
      expect(jsonDecode(body), {'hello': 'keta'});

      await server.shutdown(grace: const Duration(seconds: 1));
      expect(env.closed, isTrue);
    },
  );

  group('teardown on every path that stops owning the env', () {
    // The boot-time fail-fast the framework advertises used to leave the env
    // open and a StdoutLog's periodic timer running, so a process that caught
    // the error in order to exit cleanly hung on the timer instead. Nothing
    // between `boot()` and a bound socket released anything.
    test('a route conflict at compile closes the env before rethrowing', () {
      final env = Env(StdoutLog(flushInterval: Duration.zero));
      final app = App<Env>()
        ..get('/a', (c) => c.text('1'))
        ..get('/a', (c) => c.text('2'));

      return expectLater(
        app.serve(() async => env, port: 8093),
        throwsA(isA<StateError>()),
      ).then((_) => expect(env.closed, isTrue));
    });

    // A failing `bind` (port in use) rides the same try/catch; it is not
    // pinned separately because the transport binds `shared: true`, so a second
    // listener on a busy port succeeds rather than failing.

    test('a log is still flushed when closing the env throws', () async {
      // The pair used to run as bare sequential statements, so a pool that
      // failed to drain took the flush and the timer dispose down with it —
      // discarding the log lines that explain the failure, at the moment they
      // matter most, and leaving the process unable to exit.
      final log = _RecordingLog();
      final env = _RefusesToClose(log);
      final app = App<_RefusesToClose>()..get('/a', (c) => c.text('1'));
      final server = await app.serve(() async => env, port: 8095);

      await expectLater(
        server.shutdown(grace: const Duration(milliseconds: 100)),
        throwsA(isA<StateError>()),
      );
      expect(log.flushes, 1);
    });
  });
}

class _RefusesToClose implements HasLog, Disposable {
  _RefusesToClose(this.log);
  @override
  final Log log;

  @override
  Future<void> close() async => throw StateError('pool drain failed');
}

class _RecordingLog implements Log {
  int flushes = 0;

  @override
  Future<void> flush() async => flushes++;

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) {}
  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) {}
  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) {}
  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) {}
  @override
  Log withFields(Map<String, Object?> fields) => this;
}
