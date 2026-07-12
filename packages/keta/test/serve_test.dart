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
}
