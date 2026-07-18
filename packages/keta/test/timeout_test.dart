/// Owns the timeout() middleware: firing a 504 at the deadline while
/// completing c.aborted and warning on a late handler, and passing a
/// synchronous result or a pre-deadline error straight through.
library;

import 'dart:async';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('timeout middleware', () {
    test(
      'fires 504, completes c.aborted, and warns on late completion',
      () async {
        final env = newEnv();
        final gate = Completer<void>();
        final sawAbort = Completer<void>();
        final app = App<Env>()..use(timeout(const Duration(milliseconds: 20)));
        app.get('/slow', (c) async {
          unawaited(c.aborted.then((_) => sawAbort.complete()));
          await gate.future;
          return c.text('late');
        });
        final client = TestClient(app, env);

        final r = await client.get('/slow');
        expect(r.status, 504);
        expect(r.json(), {'error': 'request timeout'});
        await sawAbort.future.timeout(const Duration(seconds: 1));

        gate.complete();
        await pumpEventQueue();
        final lines = (env.log as MemLog).lines;
        expect(
          lines.any(
            (l) =>
                l['level'] == 'warn' &&
                l['msg'] == 'handler completed after timeout',
          ),
          isTrue,
        );
      },
    );

    test('a synchronous handler result passes through untouched', () {
      final c = testContext(newEnv());
      final result = timeout<Env>(Duration.zero)(c, (c) => c.text('sync'));
      expect(result, isA<Response>());
    });

    test('an error before the deadline propagates unchanged', () async {
      final app = App<Env>()..use(timeout(const Duration(seconds: 5)));
      app.get(
        '/boom',
        (c) async => throw const KetaException.status(418, 'teapot'),
      );
      final client = TestClient(app, newEnv());
      final r = await client.get('/boom');
      expect(r.status, 418);
    });
  });
}
