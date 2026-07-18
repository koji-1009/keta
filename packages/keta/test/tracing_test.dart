/// Owns the tracing() middleware: it populates traceKey from a valid
/// traceparent and leaves it unset on a malformed one. (Header-level parse
/// rejection is pinned in trace_context_test.dart.)
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('tracing', () {
    test('extracts a valid traceparent', () async {
      final app = App<Env>()..use(tracing());
      app.get('/t', (c) {
        final t = c.tryGet(traceKey);
        return c.json({'trace': t?.traceId});
      });
      final client = TestClient(app, newEnv());

      final r = await client.get(
        '/t',
        headers: {
          'traceparent':
              '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01',
        },
      );
      expect(r.json(), {'trace': '0af7651916cd43dd8448eb211c80319c'});
    });

    test('a malformed traceparent leaves traceKey unset', () async {
      final app = App<Env>()..use(tracing());
      app.get('/t', (c) => c.json({'set': c.tryGet(traceKey) != null}));
      final client = TestClient(app, newEnv());
      final r = await client.get(
        '/t',
        headers: {'traceparent': '00-short-bad-01'},
      );
      expect(r.json(), {'set': false});
    });
  });
}
