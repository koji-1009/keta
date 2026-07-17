@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_websocket_example/app.dart';
import 'package:test/test.dart';

/// A test env with a synchronous log so no flush timer outlives the suite.
Future<Env> boot() async => Env(StdoutLog(flushInterval: Duration.zero));

/// Mirrors lib/app.dart's demo token. The route is secure by default.
const ok = {'authorization': 'Bearer t-ok'};

void main() {
  group('the upgrade composes behind the security gate (in-process)', () {
    test('an authenticated handshake upgrades, greets, and echoes', () async {
      final client = TestClient(buildApp(), await boot());

      final up = await client.connect('/ws/echo', headers: ok);
      expect(up.upgraded, isTrue);
      final got = <Object>[];
      up.socket!.messages.listen(got.add);
      up.socket!.send('one');
      up.socket!.send('two');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The gate handed the handler the principal; the handler greeted with it,
      // then echoed each frame in order.
      expect(got, ['hello ada', 'one', 'two']);

      await up.socket!.close();
      await up.socket!.done.timeout(const Duration(seconds: 1));
    });

    test('an anonymous handshake is refused 401, never switched', () async {
      final client = TestClient(buildApp(), await boot());
      // The whole point of "upgrade as a value": the gate throws 401 before the
      // Upgrade is even built, so connect() surfaces a rejection — the response
      // the pipeline produced instead — rather than a socket.
      final rejected = await client.connect('/ws/echo');
      expect(rejected.upgraded, isFalse);
      expect(rejected.rejection!.status, 401);

      // A bad token is a 401 too — authentication failed closed, not open.
      final badToken = await client.connect(
        '/ws/echo',
        headers: const {'authorization': 'Bearer nope'},
      );
      expect(badToken.rejection!.status, 401);
    });
  });

  test('a real H1 handshake upgrades and echoes over a socket', () async {
    // The in-process path proves the composition; this proves the bundled H1
    // transport actually performs the 101 switch and frames WebSocket messages.
    final server = await buildApp().serve(boot, port: 8140);
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:8140/ws/echo',
      headers: {'authorization': 'Bearer t-ok'},
    );
    final got = <Object?>[];
    final done = Completer<void>();
    ws.listen((dynamic m) {
      got.add(m as Object?);
      if (got.length >= 2 && !done.isCompleted) done.complete();
    });
    ws.add('echo me');
    await done.future.timeout(const Duration(seconds: 5));
    expect(got, ['hello ada', 'echo me']);

    await ws.close();
    await server.shutdown(grace: const Duration(milliseconds: 200));
  });

  test('an anonymous real handshake is refused, not switched', () async {
    final server = await buildApp().serve(boot, port: 8141);
    // No credential → the server answers 401, not 101, so the client's upgrade
    // attempt fails rather than connecting.
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:8141/ws/echo'),
      throwsA(isA<WebSocketException>()),
    );
    await server.shutdown(grace: const Duration(milliseconds: 200));
  });

  test('the document projects the 101 switch and the bearer gate', () {
    final doc = buildOpenApi().toJson();
    final op = ((doc['paths'] as Map)['/ws/echo'] as Map)['get'] as Map;
    final responses = op['responses'] as Map;
    // The terminal response is a 101, not a 2xx — a SwitchingProtocols, not a
    // Success. The bearer declaration adds the 401 the handshake refusal is.
    expect(responses.containsKey('101'), isTrue);
    expect(responses.containsKey('401'), isTrue);
    expect(op['operationId'], 'echoWebSocket');
    expect(op['security'], [
      {'bearer': <String>[]},
    ]);
    // bearer reached components, carried as data by the declaration.
    expect(
      ((doc['components'] as Map)['securitySchemes'] as Map).keys,
      contains('bearer'),
    );
  });
}
