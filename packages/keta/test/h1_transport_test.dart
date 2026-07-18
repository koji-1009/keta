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

/// Sends one raw request and returns everything read back before the server
/// closes (or [wait] elapses), so header framing can be asserted directly.
Future<String> _rawExchange(int port, String request, {Duration? wait}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  socket.write(request);
  await socket.flush();
  final received = <int>[];
  final done = Completer<void>();
  socket.listen(
    received.addAll,
    onError: (_) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(
    wait ?? const Duration(milliseconds: 300),
    onTimeout: () {},
  );
  socket.destroy();
  return String.fromCharCodes(received);
}

void main() {
  group('framing (item 2)', () {
    test('a known-length body is Content-Length framed, not chunked', () async {
      final app = App<Env>();
      app.get('/s', (c) => c.text('hello world')); // String body
      app.get('/b', (c) => Response(200, body: List<int>.filled(5, 65)));
      final server = await app.serve(boot, port: 8110);

      final s = (await _rawExchange(
        8110,
        'GET /s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      )).toLowerCase();
      expect(s, contains('content-length: 11'));
      expect(s, isNot(contains('transfer-encoding')));

      final b = (await _rawExchange(
        8110,
        'GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      )).toLowerCase();
      expect(b, contains('content-length: 5'));
      expect(b, isNot(contains('transfer-encoding')));

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });

    test('a stream body is chunked, with no Content-Length', () async {
      final app = App<Env>();
      app.get(
        '/x',
        (c) => Response(
          200,
          body: Stream.fromIterable([
            const [104, 105],
          ]),
        ),
      );
      final server = await app.serve(boot, port: 8111);

      final head = (await _rawExchange(
        8111,
        'GET /x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      )).toLowerCase();
      expect(head, contains('transfer-encoding: chunked'));
      expect(head, isNot(contains('content-length')));

      await server.shutdown(grace: const Duration(milliseconds: 200));
    });
  });

  group('unread request body defense (item 3)', () {
    test(
      'an unread oversized body is refused, not drained without bound',
      () async {
        // Investigation finding pinned here: dart:io auto-drains an unread
        // request body of any size at response completion. The transport must
        // instead sever the connection, so a handler that never reads the body
        // cannot be forced to accept an arbitrarily large upload.
        final app = App<Env>();
        app.post('/ignore', (c) => c.text('ignored')); // never reads the body
        final server = await app.serve(boot, port: 8112);

        final socket = await Socket.connect(InternetAddress.loopbackIPv4, 8112);
        const declared = 64 * 1024 * 1024; // 64 MiB claimed
        socket.write(
          'POST /ignore HTTP/1.1\r\n'
          'Host: x\r\n'
          'Content-Length: $declared\r\n'
          '\r\n',
        );
        var sent = 0;
        var closed = false;
        unawaited(
          socket.done
              .then((_) => closed = true)
              .catchError((_) => closed = true),
        );
        socket.listen((_) {}, onError: (_) {});
        final chunk = List<int>.filled(64 * 1024, 65);
        final watch = Stopwatch()..start();
        while (sent < declared && !closed && watch.elapsedMilliseconds < 2000) {
          try {
            socket.add(chunk);
            sent += chunk.length;
            await socket.flush().timeout(
              const Duration(milliseconds: 100),
              onTimeout: () {},
            );
          } catch (_) {
            break;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Only the socket buffer's worth is ever accepted — nowhere near the
        // 64 MiB the client claimed. (Bounded by the OS buffer, a few MiB.)
        expect(
          sent,
          lessThan(declared ~/ 4),
          reason: 'the transport must not drain the whole oversized body',
        );

        socket.destroy();
        await server.shutdown(grace: const Duration(milliseconds: 200));
      },
    );

    test('a fully-read body still keeps the connection alive', () async {
      // The sever must be surgical: a well-behaved request that consumes its
      // body keeps keep-alive working (two requests over one socket).
      final app = App<Env>();
      app.post('/read', (c) async {
        await c.bodyBytes();
        return c.text('ok');
      });
      final server = await app.serve(boot, port: 8113);

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, 8113);
      final received = <int>[];
      socket.listen(received.addAll, onError: (_) {});
      socket.write(
        'POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.write(
        'POST /read HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\ndef',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final responses = 'HTTP/1.1 200'.allMatches(
        String.fromCharCodes(received),
      );
      expect(
        responses.length,
        2,
        reason: 'keep-alive must survive a read body',
      );

      socket.destroy();
      await server.shutdown(grace: const Duration(milliseconds: 200));
    });
  });

  group('client-disconnect detection (item 8)', () {
    test(
      'dropping the connection mid-body upload completes c.aborted',
      () async {
        // The disconnect signal dart:io *can* deliver: a client that drops
        // while still sending its body. (A drop after the full request is
        // received, during a no-write handler, is not observable — dart:io's
        // HttpServer pauses the socket read subscription while handling — and
        // is documented as a residual limitation on TransportRequest.closed.)
        final aborted = Completer<void>();
        final app = App<Env>();
        app.post('/read', (c) async {
          unawaited(
            c.aborted.then((_) {
              if (!aborted.isCompleted) aborted.complete();
            }),
          );
          await c.bodyBytes();
          return c.text('done');
        });
        final server = await app.serve(boot, port: 8114);

        final socket = await Socket.connect(InternetAddress.loopbackIPv4, 8114);
        // Claim a large body, send only a sliver, then drop mid-upload.
        socket.write(
          'POST /read HTTP/1.1\r\n'
          'Host: x\r\n'
          'Content-Length: ${1024 * 1024}\r\n'
          '\r\n',
        );
        socket.add(List<int>.filled(4096, 65));
        await socket.flush();
        socket.listen((_) {}, onError: (_) {});
        await Future<void>.delayed(const Duration(milliseconds: 100));
        socket.destroy();

        await aborted.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('c.aborted did not fire on a mid-body drop'),
        );
        expect(aborted.isCompleted, isTrue);

        await server.shutdown(grace: const Duration(milliseconds: 200));
      },
    );
  });

  group('graceful shutdown (item 2)', () {
    test(
      'a non-cooperative in-flight request still gets its full grace',
      () async {
        // Shutdown fires each in-flight request's going-away signal so a
        // cooperative stream can wind down early. A handler that ignores
        // `c.aborted` must NOT be cut short by that signal — it runs to
        // completion within the grace and its response is delivered intact.
        final started = Completer<void>();
        final app = App<Env>();
        app.get('/slow', (c) async {
          if (!started.isCompleted) started.complete();
          // Ignores c.aborted; finishes well inside the grace below.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return c.text('done');
        });
        final server = await app.serve(boot, port: 8115);

        final socket = await Socket.connect(InternetAddress.loopbackIPv4, 8115);
        socket.write(
          'GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
        );
        await socket.flush();
        final received = <int>[];
        socket.listen(received.addAll, onError: (_) {});

        await started.future.timeout(const Duration(seconds: 2));
        // Grace comfortably longer than the handler's work: it must be allowed
        // to finish, not truncated by the going-away signal.
        final watch = Stopwatch()..start();
        await server.shutdown(grace: const Duration(seconds: 5));
        watch.stop();
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason:
              'the handler finished inside the grace, so shutdown returns '
              'when it does — not at the grace deadline',
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          String.fromCharCodes(received),
          contains('done'),
          reason: 'a non-cooperative request keeps its grace and responds',
        );
        socket.destroy();
      },
    );
  });
}
