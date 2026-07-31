/// Owns [TestServer]: the harness path that puts real bytes on a real socket.
///
/// [TestClient] calls `Router.dispatch` directly, which makes it fast and
/// deterministic and also strictly weaker than production — it cannot express a
/// malformed request line, it does not carry dart:io's own framing, and a
/// synchronous throw from inside a source subscription reaches the root zone
/// rather than any future the test awaits. Those gaps are not hypothetical:
/// they are where a remote crash-the-process defect lived while the suite was
/// green. This file pins the escape hatch itself, so the tests that rely on it
/// are standing on something checked.
@TestOn('vm')
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

void main() {
  late TestServer server;

  setUp(() async {
    final app = App<Object?>()
      ..use(recover())
      ..get('/ok', (c) => c.text('hello'))
      ..post('/echo', (c) async => c.text(await c.body() as String? ?? ''))
      ..get('/boom', (c) => throw StateError('handler defect'));
    server = await TestServer.start(app, null);
  });
  tearDown(() => server.close());

  test(
    'a well-formed raw request round-trips through the full stack',
    () async {
      final raw = await server.sendRaw(
        'GET /ok HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
      );
      expect(TestServer.statusOf(raw), 200);
      expect(raw, contains('hello'));
    },
  );

  test('a malformed request line is answered, not crashed on', () {
    // The shape [TestClient] cannot produce at all: its request is built from a
    // method string and a parsed Uri, so "bytes that are not a valid request"
    // has no representation there.
    return expectLater(
      server
          .sendRaw('GET /%c0%af HTTP/1.1\r\nhost: x\r\n\r\n')
          .then(TestServer.statusOf),
      completion(isNotNull),
    );
  });

  test('a handler that throws still yields a status line', () async {
    final raw = await server.sendRaw(
      'GET /boom HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
    );
    expect(TestServer.statusOf(raw), 500);
  });

  test('a peer that half-closes mid-body is reported as no response, and '
      'leaves the server serving', () async {
    // Declares more than it sends, then goes away. The empty result IS the
    // assertion: "the request hung" and "the client left" are the same
    // observation from outside, and both must leave the next request healthy.
    final abandoned = await server.sendRaw(
      'POST /echo HTTP/1.1\r\nhost: x\r\ncontent-length: 500\r\n\r\npartial',
      halfCloseAfterWrite: true,
      timeout: const Duration(milliseconds: 300),
    );
    expect(TestServer.statusOf(abandoned), isNull);

    final after = await server.sendRaw(
      'GET /ok HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n',
    );
    expect(TestServer.statusOf(after), 200);
  });

  test('each server takes its own port, so suites do not collide', () async {
    final second = await TestServer.start(
      App<Object?>()..get('/ok', (c) => c.text('2')),
      null,
    );
    addTearDown(second.close);
    expect(second.port, isNot(server.port));
  });

  test('statusOf reads the code, and is null when nothing was answered', () {
    expect(TestServer.statusOf('HTTP/1.1 204 No Content\r\n\r\n'), 204);
    expect(TestServer.statusOf(''), isNull);
  });
}
