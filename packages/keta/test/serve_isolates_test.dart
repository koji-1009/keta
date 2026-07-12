@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:keta/keta.dart';
import 'package:test/test.dart';

class IsoEnv implements HasLog, Disposable {
  @override
  final Log log;

  IsoEnv(this.log);

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
  test('serve(isolates: n) runs multiple listeners and shuts them all down',
      () async {
    final server = await buildIsoApp().serve(bootIso, isolates: 3, port: 8092);

    final client = HttpClient();
    for (var i = 0; i < 6; i++) {
      final req =
          await client.getUrl(Uri.parse('http://127.0.0.1:8092/ping'));
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
  });

  test('a failed worker spawn tears down worker 0 (no leaked socket/env)',
      () async {
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
}
