/// Pins tx()'s post-completion guard: the DbConn published under txConn must
/// refuse further queries/executes once the transaction has committed or
/// rolled back.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:test/test.dart';

/// A minimal [Db] whose transaction runs the body on one shared connection and
/// rethrows on a throw (the rollback path), recording every call. It is
/// deliberately separate from the migration-suite `FakeDb`, which forbids
/// queries inside a transaction; here in-tx queries are exactly what must keep
/// working, so this fake permits them.
class _FakeDb implements Db {
  final _RecordingConn conn = _RecordingConn();

  @override
  DbConn get reader => conn;

  @override
  DbConn get writer => conn;

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) => f(conn);

  @override
  Future<void> close() async {}
}

class _RecordingConn implements DbConn {
  final List<String> queries = [];
  final List<String> executes = [];

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) async {
    queries.add(sql);
    return const [];
  }

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    executes.add(sql);
    return 1;
  }
}

class _Env implements HasDb {
  _Env(this.db);
  @override
  final Db db;
}

/// Matches the guard's refusal — a StateError naming the completed transaction —
/// so it is never confused with an unrelated StateError (e.g. one a handler
/// itself throws).
final _completed = isA<StateError>().having(
  (e) => e.message,
  'message',
  'transaction already completed',
);

void main() {
  group('tx() completion guard', () {
    test('in-transaction queries and executes work normally', () async {
      final db = _FakeDb();
      final c = testContext<_Env>(_Env(db));
      await tx<_Env>()(c, (c) async {
        final session = c.get(txConn);
        expect(await session.query('select 1'), isEmpty);
        expect(await session.execute('insert into t values (1)'), 1);
        return c.text('ok');
      });
      // The body's calls reached the underlying connection untouched.
      expect(db.conn.queries, ['select 1']);
      expect(db.conn.executes, ['insert into t values (1)']);
    });

    test('a query after the transaction COMMITS throws StateError', () async {
      final db = _FakeDb();
      final c = testContext<_Env>(_Env(db));
      late DbConn session;
      await tx<_Env>()(c, (c) async {
        session = c.get(txConn);
        return c.text('ok'); // normal return → commit
      });

      // The session published under txConn (e.g. captured by a streaming body
      // that runs after the handler returned) must now refuse.
      expect(() => session.query('select 1'), throwsA(_completed));
      expect(() => session.execute('delete from t'), throwsA(_completed));
      // The refusal never reached the underlying connection.
      expect(db.conn.queries, isEmpty);
      expect(db.conn.executes, isEmpty);
    });

    test(
      'a query after the transaction ROLLS BACK throws StateError',
      () async {
        final db = _FakeDb();
        final c = testContext<_Env>(_Env(db));
        late DbConn session;

        Future<Response> run() async => await tx<_Env>()(c, (c) async {
          session = c.get(txConn);
          await session.execute('insert into t values (1)');
          // A throw rolls the transaction back and propagates — the guard must
          // still trip on this path, not only on commit.
          throw StateError('handler blew up');
        });

        await expectLater(
          run(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'handler blew up',
            ),
          ),
        );

        expect(() => session.query('select 1'), throwsA(_completed));
        expect(() => session.execute('delete from t'), throwsA(_completed));
      },
    );
  });
}
