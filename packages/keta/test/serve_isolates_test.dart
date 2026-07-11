@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

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
(App<IsoEnv>, IsoEnv) isoSetup() {
  final app = App<IsoEnv>()..use(recover());
  app.get('/ping', (c) => c.json({'pong': true}));
  return (app, IsoEnv(StdoutLog(flushInterval: Duration.zero)));
}

void main() {
  test('serveIsolates runs multiple listeners and shuts them all down',
      () async {
    final server = await serveIsolates(isoSetup, isolates: 3, port: 8092);

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
}
