@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:test/test.dart';

class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

Future<Env> boot() async => Env(StdoutLog(flushInterval: Duration.zero));

Future<int> _get(HttpClient client, int port, String path) async {
  final response = await (await client.getUrl(
    Uri.parse('http://127.0.0.1:$port$path'),
  )).close();
  await response.drain<void>();
  return response.statusCode;
}

void main() {
  test('a CRLF-injecting header does not kill the server', () async {
    final app = App<Env>()..use(recover());
    app.get(
      '/bad',
      (c) => Response(
        200,
        headers: {
          'x-evil': ['a\r\nb'],
        },
      ),
    );
    app.get('/ok', (c) => c.text('ok'));
    final server = await app.serve(boot, port: 8093);
    final client = HttpClient();

    try {
      await _get(client, 8093, '/bad'); // connection may be destroyed
    } catch (_) {}
    expect(await _get(client, 8093, '/ok'), 200); // server survived

    client.close();
    await server.shutdown(grace: const Duration(milliseconds: 200));
  });

  test(
    'a body stream that errors mid-write does not kill the server',
    () async {
      Stream<List<int>> boom() async* {
        yield const [104, 105];
        throw StateError('boom');
      }

      final app = App<Env>()..use(recover());
      app.get('/throw', (c) => Response(200, body: boom()));
      app.get('/ok', (c) => c.text('ok'));
      final server = await app.serve(boot, port: 8094);
      final client = HttpClient();

      try {
        await _get(client, 8094, '/throw');
      } catch (_) {}
      expect(await _get(client, 8094, '/ok'), 200);

      client.close();
      await server.shutdown(grace: const Duration(milliseconds: 200));
    },
  );

  test(
    'a truncated stream body is aborted, never framed as complete',
    () async {
      // A chunked response is only "complete" once its zero-length terminator
      // (0\r\n\r\n) arrives. When the body producer throws mid-stream, the
      // client must instead see the connection torn down with no terminator —
      // a partial body framed as complete would be silent data corruption.
      Stream<List<int>> boom() async* {
        yield List<int>.filled(20000, 104); // large enough to flush to the wire
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw StateError('boom');
      }

      final app = App<Env>()..use(recover());
      app.get('/throw', (c) => Response(200, body: boom()));
      final server = await app.serve(boot, port: 8096);

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, 8096);
      socket.write('GET /throw HTTP/1.1\r\nHost: x\r\n\r\n');
      await socket.flush();
      final received = <int>[];
      final closed = Completer<void>();
      socket.listen(
        received.addAll,
        onError: (_) {
          if (!closed.isCompleted) closed.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );

      var hung = false;
      await closed.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => hung = true,
      );
      final text = String.fromCharCodes(received);

      expect(hung, isFalse, reason: 'the connection must be torn down');
      expect(
        text.endsWith('0\r\n\r\n'),
        isFalse,
        reason: 'no clean chunked terminator on a truncated body',
      );

      socket.destroy();
      await server.shutdown(grace: const Duration(milliseconds: 200));
    },
  );

  test('shutdown completes despite a hung handler (force-close)', () async {
    final app = App<Env>();
    app.get('/hang', (c) => Completer<Response>().future); // never completes
    final server = await app.serve(boot, port: 8095);
    final client = HttpClient();

    // Fire the hung request without awaiting; swallow its eventual socket error.
    unawaited(
      client
          .getUrl(Uri.parse('http://127.0.0.1:8095/hang'))
          .then((r) => r.close())
          .then((_) {}, onError: (_) {}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Must not hang: force-close ends it inside the grace window.
    await server
        .shutdown(grace: const Duration(milliseconds: 200))
        .timeout(const Duration(seconds: 5));
    client.close();
  });
}
