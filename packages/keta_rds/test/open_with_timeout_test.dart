/// Pins what happens to a connection whose session-level `SET
/// statement_timeout` is refused: it must be closed before the failure is
/// rethrown.
///
/// The leak this guards is unbounded by construction rather than capped at
/// `maxConnections`. `Pool` rolls its own accounting back on a failed open, so
/// a connection it never received is invisible to `poolStats` and to
/// `RdsDb.close()`, and every retry opens a fresh backend and abandons it. The
/// trigger is ordinary, not exotic: transaction-pooling proxies (pgbouncer, RDS
/// Proxy) reject `SET` outright, so it fires on every acquire against a
/// perfectly normal deployment.
///
/// Driven through a test double rather than the KETA_TEST_PG suite because a
/// real server accepts `SET` — the failure needs a connection that refuses it.
library;

import 'package:keta_rds/src/rds_db.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// A connection that reports `SET` as rejected, exactly as a transaction-mode
/// proxy does, and records whether it was closed.
class _RefusesSet implements Connection {
  bool wasClosed = false;

  @override
  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) async => throw StateError('server rejected: $query');

  @override
  Future<void> close({bool force = false}) async => wasClosed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A connection that accepts everything, to pin the success path unchanged.
class _Accepts implements Connection {
  final executed = <Object>[];
  bool wasClosed = false;

  @override
  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) async {
    executed.add(query);
    return Result(
      rows: const [],
      affectedRows: 0,
      schema: ResultSchema(const []),
    );
  }

  @override
  Future<void> close({bool force = false}) async => wasClosed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a refused SET closes the connection before rethrowing', () async {
    final conn = _RefusesSet();
    await expectLater(
      openWithTimeout(() async => conn, const Duration(seconds: 5)),
      throwsA(isA<StateError>()),
    );
    expect(
      conn.wasClosed,
      isTrue,
      reason:
          'the pool never received this connection, so nothing else can '
          'close it',
    );
  });

  test('repeated refusals leak nothing, however many times they fire', () async {
    // The shape that made this unbounded: the accounting rolls back each time,
    // so a proxy that always refuses would otherwise open a fresh backend per
    // acquire forever.
    final opened = <_RefusesSet>[];
    for (var i = 0; i < 20; i++) {
      final conn = _RefusesSet();
      opened.add(conn);
      await expectLater(
        openWithTimeout(() async => conn, const Duration(seconds: 5)),
        throwsA(isA<StateError>()),
      );
    }
    expect(opened.where((c) => !c.wasClosed), isEmpty);
  });

  test('an accepted SET hands the connection back open', () async {
    final conn = _Accepts();
    final got = await openWithTimeout(
      () async => conn,
      const Duration(milliseconds: 250),
    );
    expect(identical(got, conn), isTrue);
    expect(conn.wasClosed, isFalse);
    expect(conn.executed, ['SET statement_timeout = 250']);
  });

  test('no statementTimeout issues no statement at all', () async {
    final conn = _Accepts();
    final got = await openWithTimeout(() async => conn, null);
    expect(identical(got, conn), isTrue);
    expect(conn.executed, isEmpty);
    expect(conn.wasClosed, isFalse);
  });
}
