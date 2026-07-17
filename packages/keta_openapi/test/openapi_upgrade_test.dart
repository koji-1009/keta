import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

class Env {}

Map<String, Object?> _get(Map<String, Object?> doc, String path) {
  final paths = doc['paths']! as Map<String, Object?>;
  final item = paths[path]! as Map<String, Object?>;
  return item['get']! as Map<String, Object?>;
}

void main() {
  group('OpenAPI shadow of an upgrade route', () {
    test('emits a 101 Switching Protocols entry, not a 2xx', () {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((ch) => ch.close()),
        doc: const RouteDoc.upgrade(
          summary: 'Live feed',
          upgrade: SwitchingProtocols(subprotocol: 'chat'),
        ),
      );
      final json = OpenApi.fromRoutes(app.routes).toJson();
      final op = _get(json, '/ws');
      final responses = op['responses']! as Map<String, Object?>;

      expect(responses.keys, contains('101'));
      expect(responses.keys, isNot(contains('200')));
      final r101 = responses['101']! as Map<String, Object?>;
      expect(r101['description'], 'Switching Protocols');
      final headers = r101['headers']! as Map<String, Object?>;
      expect(headers.keys, contains('Sec-WebSocket-Protocol'));
      final scheme = headers['Sec-WebSocket-Protocol']! as Map<String, Object?>;
      expect((scheme['schema']! as Map)['const'], 'chat');
      expect(op['summary'], 'Live feed');
    });

    test('omits the subprotocol header when none is pinned', () {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((ch) => ch.close()),
        doc: const RouteDoc.upgrade(upgrade: SwitchingProtocols()),
      );
      final json = OpenApi.fromRoutes(app.routes).toJson();
      final r101 = (_get(json, '/ws')['responses']! as Map)['101']! as Map;
      expect(r101.containsKey('headers'), isFalse);
    });

    test('security still projects an automatic 401 onto the 101 route', () {
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((ch) => ch.close()),
        doc: const RouteDoc.upgrade(upgrade: SwitchingProtocols()),
      );
      final json = OpenApi.fromRoutes(app.routes, security: [bearer]).toJson();
      final op = _get(json, '/ws');
      final responses = op['responses']! as Map<String, Object?>;
      expect(responses.keys, contains('101'));
      expect(responses.keys, contains('401'));
      expect(op['security'], isNotEmpty);
    });

    test('failureResponses (e.g. a documented 426) compose on the route', () {
      const err = Schema('WsError', {'type': 'object'});
      final app = App<Env>();
      app.get(
        '/ws',
        (c) => Response.upgrade((ch) => ch.close()),
        doc: const RouteDoc.upgrade(
          upgrade: SwitchingProtocols(),
          failureResponses: {426: err},
        ),
      );
      final json = OpenApi.fromRoutes(app.routes).toJson();
      final responses =
          _get(json, '/ws')['responses']! as Map<String, Object?>;
      expect(responses.keys, contains('101'));
      expect(responses.keys, contains('426'));
      // The referenced schema is collected transitively into components.
      final components = json['components']! as Map<String, Object?>;
      final schemas = components['schemas']! as Map<String, Object?>;
      expect(schemas.keys, contains('WsError'));
    });
  });
}
