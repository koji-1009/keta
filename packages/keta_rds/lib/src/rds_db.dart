library;

import 'dart:async';

import 'package:keta_db/keta_db.dart';
// Hide the driver's own Pool: keta_rds owns pooling deliberately (a bounded,
// testable pool with keta's 503-on-exhaustion contract), and the name would
// otherwise clash with this package's Pool.
import 'package:postgres/postgres.dart' hide Pool, PoolSettings;

import 'errors.dart';
import 'pool.dart';
import 'values.dart';

/// A [Db] backed by PostgreSQL over package:postgres.
///
/// keta_rds writes no wire protocol of its own — the established pure-Dart
/// driver owns the bytes. This adapter owns three things: a bounded connection
/// [Pool] behind [reader]/[writer], the translation of the driver's errors into
/// keta's sealed exceptions (see [translating]), and the §3 type-mapping
/// contract on the rows that come back (see [mapValue]).
///
/// **The pool model.** Reads and writes each check out a connection from a pool
/// for the duration of a single `query`/`execute` call and return it
/// immediately after; [transaction] pins one connection from the writer pool
/// for its whole `BEGIN`..`COMMIT`/`ROLLBACK` span. At most [Pool.maxConnections]
/// connections are ever live per pool. When [readerEndpoint] is given, reads go
/// to a second pool aimed at that endpoint (a replica); otherwise [reader] and
/// [writer] share one pool aimed at the primary. Pool ceilings are per isolate
/// and per pool — behind a proxy such as RDS Proxy, keep them small, and size
/// the sum across isolates against the server's limit (spec §3).
///
/// **Placeholders.** SQL uses `?` positional placeholders, exactly as in
/// keta_sqlite, so the same statement runs on either engine; the driver
/// desugars them to PostgreSQL's `$1` form. A parameterless statement is sent
/// via the simple query protocol, which is what lets a migration file carry
/// several `;`-separated statements in one `execute`.
class RdsDb implements Db {
  RdsDb._(this._writerPool, this._readerPool);

  /// Connects to the primary at [endpoint] (and, if given, reads from a replica
  /// at [readerEndpoint]). [settings] is passed to every connection the pools
  /// open — set `sslMode` there. [maxConnections] and [acquireTimeout] bound
  /// each pool (see the class doc); the defaults mirror keta_sqlite's 30s lock
  /// wait and a conservative ceiling suited to a per-isolate pool behind a
  /// proxy.
  factory RdsDb(
    Endpoint endpoint, {
    Endpoint? readerEndpoint,
    ConnectionSettings? settings,
    int maxConnections = 10,
    Duration acquireTimeout = const Duration(seconds: 30),
  }) {
    Pool<Connection> poolFor(Endpoint e) => Pool<Connection>(
      () => Connection.open(e, settings: settings),
      (c) => c.close(),
      maxConnections: maxConnections,
      acquireTimeout: acquireTimeout,
    );

    final writer = poolFor(endpoint);
    final reader = readerEndpoint == null ? writer : poolFor(readerEndpoint);
    return RdsDb._(writer, reader);
  }

  /// Connects using a `postgres://user:pass@host:port/db` URL (the form the
  /// `KETA_DB` environment variable carries; see `bin/migrate.dart`). Connection
  /// options such as `sslmode` ride as URL query parameters. [readerUrl], when
  /// given, points reads at a replica. See [RdsDb] for [maxConnections] and
  /// [acquireTimeout].
  factory RdsDb.url(
    String url, {
    String? readerUrl,
    int maxConnections = 10,
    Duration acquireTimeout = const Duration(seconds: 30),
  }) {
    Pool<Connection> poolFor(String u) => Pool<Connection>(
      () => Connection.openFromUrl(u),
      (c) => c.close(),
      maxConnections: maxConnections,
      acquireTimeout: acquireTimeout,
    );

    final writer = poolFor(url);
    final reader = readerUrl == null ? writer : poolFor(readerUrl);
    return RdsDb._(writer, reader);
  }

  final Pool<Connection> _writerPool;
  final Pool<Connection> _readerPool;

  // Stamped into the transaction's zone so a nested transaction() call is
  // caught as a StateError instead of silently pinning a second connection and
  // running an independent transaction under the caller's nose.
  final Object _txZoneKey = Object();

  @override
  late final DbConn reader = _PoolConn(_readerPool);

  @override
  late final DbConn writer = _PoolConn(_writerPool);

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) {
    if (Zone.current[_txZoneKey] != null) {
      throw StateError('transactions do not nest');
    }
    return translating(() async {
      final conn = await _writerPool.acquire();
      try {
        // runTx issues BEGIN, commits on a normal return, and on a throw rolls
        // back and rethrows the ORIGINAL error (a failed ROLLBACK never masks
        // it — the driver guarantees this). Nesting is guarded above via the
        // zone, so f only ever touches the pinned TxSession.
        return await runZoned(
          () => conn.runTx((tx) => f(_TxConn(tx))),
          zoneValues: {_txZoneKey: true},
        );
      } finally {
        // A connection the driver tore down (fatal error) must not go back into
        // the pool; isOpen tells us whether it survived.
        _writerPool.release(conn, broken: !conn.isOpen);
      }
    });
  }

  @override
  Future<void> close() async {
    await _writerPool.close();
    if (!identical(_readerPool, _writerPool)) {
      await _readerPool.close();
    }
  }
}

/// A [DbConn] over a [Pool]: each call checks out a connection, runs, and
/// returns it. Errors are translated and rows mapped on the way out.
class _PoolConn implements DbConn {
  _PoolConn(this._pool);

  final Pool<Connection> _pool;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) => _use((c) => _runQuery(c, sql, params));

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) =>
      _use((c) => _runExecute(c, sql, params));

  Future<R> _use<R>(Future<R> Function(Connection) op) => translating(() async {
    final conn = await _pool.acquire();
    try {
      return await op(conn);
    } finally {
      _pool.release(conn, broken: !conn.isOpen);
    }
  });
}

/// A [DbConn] bound to a live [TxSession] for the body of [RdsDb.transaction].
/// It runs on the pinned connection; commit/rollback is `runTx`'s job.
class _TxConn implements DbConn {
  _TxConn(this._session);

  final TxSession _session;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) => _runQuery(_session, sql, params);

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) =>
      _runExecute(_session, sql, params);
}

/// Runs a row-returning query on [session] and maps the rows. Uses the extended
/// query protocol so values come back in their real types (int, double,
/// String-valued numeric, DateTime, …) rather than as protocol text.
Future<List<Map<String, Object?>>> _runQuery(
  Session session,
  String sql,
  List<Object?> params,
) async {
  final result = await session.execute(
    params.isEmpty ? sql : Sql.indexed(sql, substitution: '?'),
    parameters: params.isEmpty ? null : params,
  );
  return [for (final row in result) mapRow(row)];
}

/// Runs a statement on [session] and returns the affected-row count. A
/// parameterless statement goes through the simple query protocol (the driver
/// picks it automatically for a parameterless `ignoreRows` execute), which is
/// what allows a migration's several `;`-separated statements to run in one
/// call; a parameterized statement is prepared and bound via `?` placeholders.
Future<int> _runExecute(
  Session session,
  String sql,
  List<Object?> params,
) async {
  final result = await session.execute(
    params.isEmpty ? sql : Sql.indexed(sql, substitution: '?'),
    parameters: params.isEmpty ? null : params,
    ignoreRows: true,
  );
  return result.affectedRows;
}
