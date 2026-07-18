/// `RouteDoc`'s free-form metadata (`description`, `tags`, `operationId`):
/// each projects onto its operation as declared, `tags` additionally
/// aggregates into a sorted/deduped document-wide list, `operationId` is
/// enforced document-wide unique, and none of this depends on registration
/// order.
library;

import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

class Ignored {}

Map<String, Object?> _get(Map<String, Object?> doc, String path) =>
    ((doc['paths'] as Map)[path] as Map)['get'] as Map<String, Object?>;

void main() {
  group('RouteDoc description / tags / operationId', () {
    test('description and tags project onto the operation', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(
            success: Success(),
            description: 'Fetch a user by id.',
            tags: ['users', 'read'],
          ),
        );
      final op = _get(OpenApi.fromRoutes(app.routes).toJson(), '/u');
      expect(op['description'], 'Fetch a user by id.');
      // Operation-level tags are the author's declared list, projected as-is.
      expect(op['tags'], ['users', 'read']);
    });

    test('operationId projects onto the operation', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success(), operationId: 'getUser'),
        );
      expect(
        _get(OpenApi.fromRoutes(app.routes).toJson(), '/u')['operationId'],
        'getUser',
      );
    });

    test('all three are absent when undeclared', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success()),
        );
      final op = _get(OpenApi.fromRoutes(app.routes).toJson(), '/u');
      expect(op.containsKey('description'), isFalse);
      expect(op.containsKey('tags'), isFalse);
      expect(op.containsKey('operationId'), isFalse);
    });

    test('tags aggregate into a sorted, deduped top-level list', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success(), tags: ['users', 'read']),
        )
        ..get(
          '/o',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success(), tags: ['orders', 'users']),
        );
      final doc = OpenApi.fromRoutes(app.routes).toJson();
      // Union {users, read, orders} → sorted, deduped, as Tag objects.
      expect(doc['tags'], [
        {'name': 'orders'},
        {'name': 'read'},
        {'name': 'users'},
      ]);
    });

    test('no top-level tags key when no route declares any', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success()),
        );
      expect(
        OpenApi.fromRoutes(app.routes).toJson().containsKey('tags'),
        isFalse,
      );
    });

    test('the document stays deterministic across registration order with '
        'tags present', () {
      App<Ignored> build(List<String> paths) {
        final app = App<Ignored>();
        for (final p in paths) {
          app.get(
            p,
            (c) => c.text('x'),
            doc: RouteDoc(
              success: const Success(),
              tags: p == '/a' ? const ['x', 'y'] : const ['y', 'z'],
              operationId: 'op${p.substring(1)}',
            ),
          );
        }
        return app;
      }

      expect(
        OpenApi.fromRoutes(build(['/b', '/a']).routes).toYaml(),
        OpenApi.fromRoutes(build(['/a', '/b']).routes).toYaml(),
      );
    });

    test('a duplicate operationId is a hard error naming both routes', () {
      final app = App<Ignored>()
        ..get(
          '/a',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success(), operationId: 'dup'),
        )
        ..get(
          '/b',
          (c) => c.text('x'),
          doc: const RouteDoc(success: Success(), operationId: 'dup'),
        );
      expect(
        () => OpenApi.fromRoutes(app.routes),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('"dup"'), contains('GET /a'), contains('GET /b')),
          ),
        ),
      );
    });

    test(
      'the same operationId on the same route across two documents is fine',
      () {
        // Uniqueness is within one document, not across builds — a second
        // OpenApi.fromRoutes over the same app must not carry state from the
        // first.
        final app = App<Ignored>()
          ..get(
            '/a',
            (c) => c.text('x'),
            doc: const RouteDoc(success: Success(), operationId: 'once'),
          );
        expect(() => OpenApi.fromRoutes(app.routes), returnsNormally);
        expect(() => OpenApi.fromRoutes(app.routes), returnsNormally);
      },
    );
  });
}
