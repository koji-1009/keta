/// OpenAPI-doc conformance: buildOpenApi() is asserted against, not a
/// hand-rolled fromRoutes — the document tool/openapi.dart actually emits —
/// so these prove the paths match what is registered, and that the shapes the
/// string-route syntax cannot express (the SSE feed's per-event schema, the
/// custom Role capture's enum) are documented as what they truly are.
library;

import 'package:keta_register_example/app.dart';
import 'package:test/test.dart';

void main() {
  test('OpenAPI output mirrors the registered routes', () {
    final paths = (buildOpenApi().toJson()['paths'] as Map).keys;
    expect(
      paths,
      containsAll([
        '/health',
        '/users/{id}',
        '/users',
        '/users/{uid}/tags/{index}',
        '/users/by-role/{role}',
        '/users/events',
      ]),
    );
  });

  test('the SSE route and the custom capture document their true shapes', () {
    final doc = buildOpenApi().toJson();
    Map<String, Object?> op(String path) =>
        ((doc['paths'] as Map)[path] as Map)['get'] as Map<String, Object?>;

    // The SSE route's success is a 200 under text/event-stream, whose schema is
    // the per-event data payload (UserEvent) — the content type names the
    // transport, the schema names what one event decodes to.
    final sse = op('/users/events');
    final sse200 = ((sse['responses'] as Map)['200'] as Map)['content'] as Map;
    expect(sse200.keys, ['text/event-stream']);
    expect((sse200['text/event-stream'] as Map)['schema'], {
      r'$ref': '#/components/schemas/UserEvent',
    });
    expect(sse['operationId'], 'streamUserEvents');
    // Inheriting the secure-by-default bearer earns it an automatic 401.
    expect((sse['responses'] as Map).containsKey('401'), isTrue);

    // The custom Role capture projects its enum schema onto the path parameter.
    final byRole =
        ((doc['paths'] as Map)['/users/by-role/{role}'] as Map)['get'] as Map;
    final roleParam = (byRole['parameters'] as List).firstWhere(
      (p) => (p as Map)['name'] == 'role',
    );
    expect((roleParam as Map)['schema'], {
      'type': 'string',
      'enum': ['admin', 'member'],
    });
  });
}
