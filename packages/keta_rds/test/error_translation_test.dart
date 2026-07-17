import 'dart:io' show SocketException;

import 'package:keta/keta.dart' show Conflict, KetaException, Unavailable;
import 'package:keta_rds/src/errors.dart';
// Reaching into the driver's internals is deliberate here: it is the only way
// to synthesize a realistic ServerException (its constructors are private)
// carrying a chosen SQLSTATE, so the translation floor can be exercised without
// a live server. This coupling lives only in the test, never in lib/.
import 'package:postgres/postgres.dart'
    show PgException, ServerException, Severity;
import 'package:postgres/src/exceptions.dart'
    show buildExceptionFromErrorFields;
import 'package:postgres/src/messages/server_messages.dart'
    show ErrorField, ErrorFieldId;
import 'package:test/test.dart';

ServerException serverException(
  String code, {
  String message = 'boom',
  String? detail,
  String? constraint,
  String severity = 'ERROR',
}) => buildExceptionFromErrorFields([
  ErrorField(ErrorFieldId.severity, severity),
  ErrorField(ErrorFieldId.code, code),
  ErrorField(ErrorFieldId.message, message),
  if (detail != null) ErrorField(ErrorFieldId.detail, detail),
  if (constraint != null) ErrorField(ErrorFieldId.constraint, constraint),
]);

// Feeding a synthesized driver exception in is the whole point; the object
// under test is translating(), not the throw.
Future<T> throwing<T>(Object error) =>
    // ignore: only_throw_errors
    translating<T>(() async => throw error);

void main() {
  group('translated conditions', () {
    test('a uniqueness violation (23505) becomes a Conflict', () async {
      await expectLater(
        throwing<void>(
          serverException(
            uniqueViolation,
            message: 'duplicate key value violates unique constraint "u_email"',
            detail: 'Key (email)=(a@x) already exists.',
            constraint: 'u_email',
          ),
        ),
        throwsA(
          isA<Conflict>()
              .having((e) => e.status, 'status', 409)
              .having((e) => e.message, 'message', 'row already exists'),
        ),
      );
    });

    test(
      'the collision detail is carried, but not shown to the client',
      () async {
        try {
          await throwing<void>(
            serverException(
              uniqueViolation,
              detail: 'Key (email)=(a@x) already exists.',
              constraint: 'u_email',
            ),
          );
          fail('expected a Conflict');
        } on Conflict catch (e) {
          // The operator needs to know which constraint collided...
          expect(e.detail.toString(), contains('u_email'));
          // ...and the client, reading only KetaException.toString(), does not.
          expect(e.toString(), isNot(contains('u_email')));
        }
      },
    );

    test('lock_not_available (55P03) becomes Unavailable', () async {
      await expectLater(
        throwing<void>(serverException(lockNotAvailable)),
        throwsA(isA<Unavailable>().having((e) => e.status, 'status', 503)),
      );
    });

    test('too_many_connections (53300) becomes Unavailable', () async {
      await expectLater(
        throwing<void>(serverException(tooManyConnections)),
        throwsA(isA<Unavailable>()),
      );
    });

    test('cannot_connect_now (57P03) becomes Unavailable', () async {
      await expectLater(
        throwing<void>(serverException(cannotConnectNow)),
        throwsA(isA<Unavailable>()),
      );
    });

    test(
      'an unreachable server (SocketException) becomes Unavailable',
      () async {
        await expectLater(
          throwing<void>(const SocketException('Connection refused')),
          throwsA(isA<Unavailable>()),
        );
      },
    );

    test('a connection-fatal PgException becomes Unavailable', () async {
      await expectLater(
        throwing<void>(
          PgException('the socket died', severity: Severity.fatal),
        ),
        throwsA(isA<Unavailable>()),
      );
    });
  });

  group(
    'conditions left raw (the floor is not a ceiling in the wrong direction)',
    () {
      test('a NOT NULL violation (23502) passes through untranslated', () async {
        await expectLater(
          throwing<void>(serverException('23502', message: 'null value')),
          throwsA(
            isA<ServerException>()
                .having((e) => e.code, 'code', '23502')
                // Emphatically NOT a KetaException: narrowing to ServerException
                // alone would still pass if translation had swallowed it.
                .having((e) => e, 'not keta', isNot(isA<KetaException>())),
          ),
        );
      });

      test(
        'a foreign-key violation (23503) passes through untranslated',
        () async {
          await expectLater(
            throwing<void>(serverException('23503')),
            throwsA(
              isA<ServerException>().having((e) => e.code, 'code', '23503'),
            ),
          );
        },
      );

      test('a non-fatal query-level PgException passes through', () async {
        await expectLater(
          throwing<void>(PgException('some client-side error')),
          throwsA(
            isA<PgException>().having(
              (e) => e,
              'not keta',
              isNot(isA<KetaException>()),
            ),
          ),
        );
      });

      test(
        'a keta exception thrown from within passes through unchanged',
        () async {
          const original = Unavailable('pool exhausted');
          await expectLater(throwing<void>(original), throwsA(same(original)));
        },
      );
    },
  );
}
