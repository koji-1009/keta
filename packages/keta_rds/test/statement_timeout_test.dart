/// Pins RdsDb's statementTimeout validation — the part that needs no live
/// Postgres. Construction is lazy (no connection is opened until a pool is
/// first used), so a rejected value must fail at construction, synchronously,
/// before any socket work. The live behaviour (the SET landing on the wire and
/// SQLSTATE 57014 surfacing as a raw 500) is exercised by the KETA_TEST_PG
/// contract suite instead, because it cannot be observed without a server.
library;

import 'package:keta_rds/keta_rds.dart';
import 'package:test/test.dart';

final _endpoint = Endpoint(host: 'localhost', database: 'x');
const _url = 'postgres://u:p@localhost:5432/x';

void main() {
  group('statementTimeout validation', () {
    test('a zero duration is rejected (it caps nothing)', () {
      expect(
        () => RdsDb(_endpoint, statementTimeout: Duration.zero),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.name,
            'name',
            'statementTimeout',
          ),
        ),
      );
    });

    test('a negative duration is rejected', () {
      expect(
        () => RdsDb(
          _endpoint,
          statementTimeout: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('a positive but sub-millisecond duration is rejected (it rounds to 0, '
        'which PostgreSQL reads as disabled)', () {
      expect(
        () => RdsDb(
          _endpoint,
          statementTimeout: const Duration(microseconds: 500),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('millisecond'),
          ),
        ),
      );
    });

    test('the url constructor validates identically', () {
      expect(
        () => RdsDb.url(_url, statementTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => RdsDb.url(
          _url,
          statementTimeout: const Duration(microseconds: 500),
        ),
        throwsArgumentError,
      );
    });

    test(
      'a valid millisecond-or-greater duration constructs without error',
      () {
        // No connection is opened here — construction only builds the (lazy)
        // pools — so a valid value must not throw. addTearDown closes the pools
        // it created so no timer or resource is left armed.
        final db = RdsDb(
          _endpoint,
          statementTimeout: const Duration(seconds: 5),
        );
        addTearDown(db.close);
        expect(db, isA<RdsDb>());

        final byUrl = RdsDb.url(
          _url,
          statementTimeout: const Duration(milliseconds: 1),
        );
        addTearDown(byUrl.close);
        expect(byUrl, isA<RdsDb>());
      },
    );

    test('omitting statementTimeout is allowed (the cap is opt-in)', () {
      final db = RdsDb(_endpoint);
      addTearDown(db.close);
      expect(db, isA<RdsDb>());
    });
  });
}
