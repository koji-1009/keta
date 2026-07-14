import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

class Ignored {}

const createdSchema = Schema('Created', {
  'type': 'object',
  'required': ['type', 'at'],
  'properties': {
    'type': {'type': 'string'},
    'at': {'type': 'string'},
  },
});
const deletedSchema = Schema('Deleted', {
  'type': 'object',
  'required': ['type', 'reason'],
  'properties': {
    'type': {'type': 'string'},
    'reason': {'type': 'string'},
  },
});
const eventSchema = Schema(
  'Event',
  {
    'oneOf': [
      {r'$ref': '#/components/schemas/Created'},
      {r'$ref': '#/components/schemas/Deleted'},
    ],
    'discriminator': {
      'propertyName': 'type',
      'mapping': {
        'created': '#/components/schemas/Created',
        'deleted': '#/components/schemas/Deleted',
      },
    },
  },
  deps: [createdSchema, deletedSchema],
);

void main() {
  test('override receives the finished document and may rewrite it', () {
    final app = App<Ignored>()..get('/x', (c) => c.text('x'));
    Map<String, Object?>? seen;
    final spec = OpenApi.fromRoutes(
      app.routes,
      override: (doc) {
        seen = doc;
        return {...doc, 'x-audience': 'internal'};
      },
    );
    expect(seen!['openapi'], '3.1.0');
    expect(spec.toJson()['x-audience'], 'internal');
  });

  test('referenced schemas are collected transitively and de-duplicated', () {
    final app = App<Ignored>()
      ..get(
        '/events',
        (c) => c.text('x'),
        doc: const RouteDoc(response: eventSchema),
      )
      ..get(
        '/events2',
        (c) => c.text('x'),
        doc: const RouteDoc(response: eventSchema),
      );
    final schemas =
        (OpenApi.fromRoutes(app.routes).toJson()['components']
                as Map)['schemas']
            as Map;
    expect(schemas.keys, unorderedEquals(['Event', 'Created', 'Deleted']));
    expect(schemas['Created'], createdSchema.json);
  });

  test('a null or non-RouteDoc doc still emits an operation', () {
    final app = App<Ignored>()
      ..get('/plain', (c) => c.text('x'))
      ..get('/weird', (c) => c.text('x'), doc: 'not-a-doc');
    final doc = OpenApi.fromRoutes(app.routes).toJson();
    for (final path in ['/plain', '/weird']) {
      final op = ((doc['paths'] as Map)[path] as Map)['get'] as Map;
      expect(op.containsKey('summary'), isFalse);
      expect(op['responses'], {
        '200': {'description': 'OK'},
      });
    }
    expect(doc.containsKey('components'), isFalse);
  });

  test('a documented route with no response fabricates a 200', () {
    final app = App<Ignored>()
      ..get('/s', (c) => c.text('x'), doc: const RouteDoc(summary: 'just s'));
    final op =
        ((OpenApi.fromRoutes(app.routes).toJson()['paths'] as Map)['/s']
                as Map)['get']
            as Map;
    expect(op['summary'], 'just s');
    expect(op['responses'], {
      '200': {'description': 'OK'},
    });
  });

  test('nameless captures become p{index} with their schema fragment', () {
    final app = App<Ignored>();
    app
        .on(root.segments('users').capture(integer).segments('score').capture(number))
        .get((c, p) => c.text('x'));
    final doc = OpenApi.fromRoutes(app.routes).toJson();
    final paths = doc['paths'] as Map;
    expect(paths.keys, ['/users/{p0}/score/{p1}']);
    final params =
        ((paths.values.single as Map)['get'] as Map)['parameters'] as List;
    expect((params[0] as Map)['name'], 'p0');
    expect(((params[0] as Map)['schema'] as Map)['type'], 'integer');
    expect((params[1] as Map)['name'], 'p1');
    expect(((params[1] as Map)['schema'] as Map)['type'], 'number');
  });

  test('a custom capture projects its schema fragment verbatim', () {
    final color = Capture<String>(
      (s) => s,
      schema: {
        'type': 'string',
        'enum': ['red', 'green'],
      },
    );
    final app = App<Ignored>();
    app
        .on(root.segments('c').capture(color('shade')))
        .get((c, p) => c.text('x'));
    final params =
        (((OpenApi.fromRoutes(app.routes).toJson()['paths']
                        as Map)['/c/{shade}']
                    as Map)['get']
                as Map)['parameters']
            as List;
    expect((params.single as Map)['schema'], {
      'type': 'string',
      'enum': ['red', 'green'],
    });
  });

  test(
    'a mixed named/nameless capture path counts every capture in the index',
    () {
      final app = App<Ignored>();
      app
          .on(root.capture(integer('id')).capture(number))
          .get((c, p) => c.text('x'));
      final paths = OpenApi.fromRoutes(app.routes).toJson()['paths'] as Map;
      expect(paths.keys, ['/{id}/{p1}']);
    },
  );

  test('an empty path maps to "/"', () {
    final app = App<Ignored>()..get('/', (c) => c.text('x'));
    expect((OpenApi.fromRoutes(app.routes).toJson()['paths'] as Map).keys, [
      '/',
    ]);
  });

  test('a duplicate path-parameter name fails fast', () {
    // A user-named capture 'p0' collides with the auto-name of the first
    // capture, which would emit an invalid `/{p0}/{p0}` template. (App-level
    // registration also rejects this; here we drive OpenApi directly with a
    // RouteEntry to prove the emitter guards it independently.)
    final route = RouteEntry(
      'GET',
      [const CaptureSegment(integer), CaptureSegment(number('p0'))],
      null,
      '/:p0/:p0',
    );
    expect(
      () => OpenApi.fromRoutes([route]),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('duplicate path parameter'),
        ),
      ),
    );
  });

  group('security', () {
    Map<String, Object?> op(Map<String, Object?> doc, String path) =>
        ((doc['paths'] as Map)[path] as Map)['get'] as Map<String, Object?>;

    test('a declared scheme emits per-op security, the component, and a 401', () {
      final app = App<Ignored>()
        ..get(
          '/secret',
          (c) => c.text('x'),
          doc: const RouteDoc(security: [bearer]),
        );
      final doc = OpenApi.fromRoutes(app.routes).toJson();
      final o = op(doc, '/secret');
      expect(o['security'], [
        {'bearer': <String>[]},
      ]);
      expect((o['responses'] as Map).containsKey('401'), isTrue);
      expect(((doc['components'] as Map)['securitySchemes'] as Map)['bearer'], {
        'type': 'http',
        'scheme': 'bearer',
      });
    });

    test('the global default applies where a route declares none', () {
      final app = App<Ignored>()..get('/x', (c) => c.text('x'));
      final doc = OpenApi.fromRoutes(app.routes, security: [bearer]).toJson();
      expect(op(doc, '/x')['security'], [
        {'bearer': <String>[]},
      ]);
    });

    test('an empty security list overrides the default to public', () {
      final app = App<Ignored>()
        ..get('/open', (c) => c.text('x'), doc: const RouteDoc(security: []));
      final doc = OpenApi.fromRoutes(app.routes, security: [bearer]).toJson();
      final o = op(doc, '/open');
      expect(o.containsKey('security'), isFalse);
      expect((o['responses'] as Map).containsKey('401'), isFalse);
      expect(doc.containsKey('components'), isFalse);
    });

    test('a user-declared 401 wins over the automatic one', () {
      final app = App<Ignored>()
        ..get(
          '/s',
          (c) => c.text('x'),
          doc: const RouteDoc(
            security: [bearer],
            responses: {401: createdSchema},
          ),
        );
      final doc = OpenApi.fromRoutes(app.routes).toJson();
      final r401 = (op(doc, '/s')['responses'] as Map)['401'] as Map;
      expect(r401.containsKey('content'), isTrue); // the user's body, not bare
    });
  });
}
