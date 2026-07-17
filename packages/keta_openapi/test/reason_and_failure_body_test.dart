import 'package:keta/keta.dart';
import 'package:keta_openapi/keta_openapi.dart';
import 'package:test/test.dart';

class Ignored {}

const bodySchema = Schema('Body', {'type': 'object'});
const errorSchema = Schema('Error', {'type': 'object'});

Map<String, Object?> _op(App<Ignored> app, String path, String method) {
  final paths = OpenApi.fromRoutes(app.routes).toJson()['paths'] as Map;
  return (paths[path] as Map)[method] as Map<String, Object?>;
}

void main() {
  group(
    'response descriptions are RFC 9110 reason phrases, not a fixed OK',
    () {
      test('a 201 success is "Created", not "OK"', () {
        final app = App<Ignored>()
          ..post(
            '/u',
            (c) => c.text('x', status: 201),
            doc: const RouteDoc(success: Success(status: 201)),
          );
        final r = (_op(app, '/u', 'post')['responses'] as Map)['201'] as Map;
        expect(r['description'], 'Created');
      });

      test('a 204 success is "No Content", not "OK"', () {
        final app = App<Ignored>()
          ..delete(
            '/u',
            (c) => c.text('', status: 204),
            doc: const RouteDoc(success: Success(status: 204)),
          );
        final r = (_op(app, '/u', 'delete')['responses'] as Map)['204'] as Map;
        expect(r['description'], 'No Content');
      });

      test('a 302 success is "Found", not "OK"', () {
        final app = App<Ignored>()
          ..get(
            '/r',
            (c) => c.text('x'),
            doc: const RouteDoc(success: Success(status: 302)),
          );
        final r = (_op(app, '/r', 'get')['responses'] as Map)['302'] as Map;
        expect(r['description'], 'Found');
      });

      test('a 200 stays "OK"', () {
        final app = App<Ignored>()
          ..get(
            '/u',
            (c) => c.text('x'),
            doc: const RouteDoc(success: Success()),
          );
        final r = (_op(app, '/u', 'get')['responses'] as Map)['200'] as Map;
        expect(r['description'], 'OK');
      });

      test('failure descriptions carry their reason phrase, not ""', () {
        final app = App<Ignored>()
          ..get(
            '/u',
            (c) => c.text('x'),
            doc: const RouteDoc(
              success: Success(),
              failureResponses: {403: errorSchema, 404: errorSchema},
            ),
          );
        final responses = _op(app, '/u', 'get')['responses'] as Map;
        expect((responses['403'] as Map)['description'], 'Forbidden');
        expect((responses['404'] as Map)['description'], 'Not Found');
      });

      test('a code with no registered name falls back to "Status <code>"', () {
        // 599 is a valid 400-599 failure key with no IANA/RFC 9110 name — the
        // honest fallback, not a blank or a fabricated phrase.
        final app = App<Ignored>()
          ..get(
            '/u',
            (c) => c.text('x'),
            doc: const RouteDoc(
              success: Success(),
              failureResponses: {599: errorSchema},
            ),
          );
        final r = (_op(app, '/u', 'get')['responses'] as Map)['599'] as Map;
        expect(r['description'], 'Status 599');
      });
    },
  );

  group('a failure may declare a non-JSON media type', () {
    test('a bare Schema failure is still application/json', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(
            success: Success(),
            failureResponses: {400: errorSchema},
          ),
        );
      final r = (_op(app, '/u', 'get')['responses'] as Map)['400'] as Map;
      expect((r['content'] as Map).keys, ['application/json']);
    });

    test('a Failure projects its declared content type', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(
            success: Success(),
            failureResponses: {
              422: Failure(
                errorSchema,
                contentType: 'application/problem+json',
              ),
            },
          ),
        );
      final r = (_op(app, '/u', 'get')['responses'] as Map)['422'] as Map;
      expect((r['content'] as Map).keys, ['application/problem+json']);
      final ref =
          (((r['content'] as Map)['application/problem+json'] as Map)['schema']
              as Map)[r'$ref'];
      expect(ref, '#/components/schemas/Error');
    });

    test('a Failure schema is collected into components', () {
      final app = App<Ignored>()
        ..get(
          '/u',
          (c) => c.text('x'),
          doc: const RouteDoc(
            success: Success(),
            failureResponses: {
              415: Failure(errorSchema, contentType: 'text/plain'),
            },
          ),
        );
      final schemas =
          (OpenApi.fromRoutes(app.routes).toJson()['components']
                  as Map)['schemas']
              as Map;
      expect(schemas.keys, contains('Error'));
    });

    test(
      'a failure value that is neither Schema nor Failure is a hard error',
      () {
        // `Map<int, Object>` cannot exclude a stray String; the emit-time check
        // is what holds the union, naming the route.
        final app = App<Ignored>()
          ..get(
            '/u',
            (c) => c.text('x'),
            doc: const RouteDoc(
              success: Success(),
              failureResponses: {500: 'not a schema'},
            ),
          );
        expect(
          () => OpenApi.fromRoutes(app.routes),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('GET /u'),
                contains('500'),
                contains('Schema or a Failure'),
              ),
            ),
          ),
        );
      },
    );
  });
}
