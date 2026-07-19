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
/// **Statement timeout.** When `statementTimeout` is passed to a constructor,
/// keta_rds issues a session-level `SET statement_timeout` on every connection
/// its pools open, so no single statement can run longer than that duration.
/// The cap fires server-side (SQLSTATE 57014, query_canceled) and surfaces as a
/// plain 500 — keta_rds does not translate 57014, and a statement that blew its
/// own deadline is deliberately not retryable. See [_openWithTimeout].
///
/// **Disconnect recovery.** A connection the driver tears down mid-session
/// (dead socket, server-initiated shutdown) is disposed rather than returned
/// to the pool — see [translating] — and the next `acquire` opens a fresh one.
/// Retrying the in-flight query itself is deliberately absent: whether it was
/// safe to run again is unknowable at this layer.
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
  ///
  /// [statementTimeout], when given, caps how long any single statement may run
  /// on a pooled connection (see the class doc and [_openWithTimeout]); a
  /// non-positive or sub-millisecond value is rejected here at construction.
  factory RdsDb(
    Endpoint endpoint, {
    Endpoint? readerEndpoint,
    ConnectionSettings? settings,
    int maxConnections = 10,
    Duration acquireTimeout = const Duration(seconds: 30),
    Duration? statementTimeout,
  }) {
    _validateStatementTimeout(statementTimeout);
    Pool<Connection> poolFor(Endpoint e) => Pool<Connection>(
      () => _openWithTimeout(
        () => Connection.open(e, settings: settings),
        statementTimeout,
      ),
      (c) => c.close(),
      maxConnections: maxConnections,
      acquireTimeout: acquireTimeout,
      // Skip and replace an idle connection the server dropped: isOpen is the
      // driver's own liveness bit, so a proxy/NAT-reaped socket is reopened at
      // acquire rather than surfacing as one failed query.
      validate: (c) => c.isOpen,
    );

    final writer = poolFor(endpoint);
    final reader = readerEndpoint == null ? writer : poolFor(readerEndpoint);
    return RdsDb._(writer, reader);
  }

  /// Connects using a `postgres://user:pass@host:port/db` URL (the form the
  /// `KETA_DB` environment variable carries; see `bin/migrate.dart`). Connection
  /// options such as `sslmode` ride as URL query parameters. [readerUrl], when
  /// given, points reads at a replica. See [RdsDb] for [maxConnections],
  /// [acquireTimeout], and [statementTimeout].
  factory RdsDb.url(
    String url, {
    String? readerUrl,
    int maxConnections = 10,
    Duration acquireTimeout = const Duration(seconds: 30),
    Duration? statementTimeout,
  }) {
    _validateStatementTimeout(statementTimeout);
    Pool<Connection> poolFor(String u) => Pool<Connection>(
      () => _openWithTimeout(() => Connection.openFromUrl(u), statementTimeout),
      (c) => c.close(),
      maxConnections: maxConnections,
      acquireTimeout: acquireTimeout,
      // See the sibling factory: isOpen replaces a server-dropped idle socket.
      validate: (c) => c.isOpen,
    );

    final writer = poolFor(url);
    final reader = readerUrl == null ? writer : poolFor(readerUrl);
    return RdsDb._(writer, reader);
  }

  /// Rejects a [statementTimeout] that could never mean "cap statements at this
  /// duration". A non-positive value is a plain mistake; a positive but
  /// sub-millisecond value is worse than a mistake, because PostgreSQL's
  /// `statement_timeout` is expressed in whole milliseconds and rounds it to
  /// `0`, which PostgreSQL reads as *disabled* — the exact opposite of the
  /// caller's intent. Both are refused loudly at construction rather than
  /// silently opening connections with no cap.
  static void _validateStatementTimeout(Duration? statementTimeout) {
    if (statementTimeout == null) return;
    if (statementTimeout <= Duration.zero) {
      throw ArgumentError.value(
        statementTimeout,
        'statementTimeout',
        'must be a positive duration (a non-positive timeout caps nothing)',
      );
    }
    if (statementTimeout.inMilliseconds < 1) {
      throw ArgumentError.value(
        statementTimeout,
        'statementTimeout',
        'must be at least 1 millisecond; PostgreSQL rounds a sub-millisecond '
            'statement_timeout to 0, which disables the cap entirely',
      );
    }
  }

  /// Opens a connection via [open] and, when [statementTimeout] is set, pins a
  /// session-level `statement_timeout` on it before it is ever handed out, so
  /// every connection any pool opens carries the cap. Issued at open time (not
  /// per query) because it is a session GUC that survives for the connection's
  /// life; a pooled connection therefore inherits it once and keeps it.
  ///
  /// When the cap fires, PostgreSQL cancels the running statement server-side
  /// with SQLSTATE 57014 (query_canceled). keta_rds does NOT translate 57014
  /// (that is outside this option's remit): it surfaces as the driver's own
  /// `ServerException`, which — like any untranslated server error — becomes a
  /// plain 500. It is deliberately neither a [Unavailable] nor a
  /// [TransientFailure]: a statement that blew its own deadline is not something
  /// to blindly retry.
  static Future<Connection> _openWithTimeout(
    Future<Connection> Function() open,
    Duration? statementTimeout,
  ) async {
    final conn = await open();
    if (statementTimeout != null) {
      // A whole-number millisecond literal; PostgreSQL reads a bare integer as
      // milliseconds. Not a placeholder-bound value: SET does not accept
      // parameters, and the integer is framework-computed, never user input.
      await conn.execute(
        'SET statement_timeout = ${statementTimeout.inMilliseconds}',
      );
    }
    return conn;
  }

  final Pool<Connection> _writerPool;
  final Pool<Connection> _readerPool;

  // Stamped into the transaction's zone so a nested transaction() call is
  // caught as a StateError instead of silently pinning a second connection and
  // running an independent transaction under the caller's nose. Each
  // transaction() call stamps a *fresh* token (not a constant), and the
  // no-nest check below is a membership test against the tokens of
  // transactions genuinely running right now — mirroring keta_sqlite's
  // identity-checked _inActiveTxZone (sqlite_db.dart) — so a zone captured
  // inside one transaction and leaked or reused after that transaction
  // finished is not mistaken for nesting just because the token object still
  // exists somewhere. Unlike keta_sqlite's single serialized connection (at
  // most one transaction ever active, so a single field suffices), RdsDb pools
  // several connections and genuinely concurrent transactions are normal
  // (see the contract suite's "concurrent transactions serialize" test), so a
  // *set* of the currently-live tokens stands in for sqlite's single
  // `_currentTx` field.
  final Object _txZoneKey = Object();
  final Set<Object> _activeTx = {};

  @override
  late final DbConn reader = _PoolConn(_readerPool);

  @override
  late final DbConn writer = _PoolConn(_writerPool);

  /// Pins one connection from the writer pool for the whole
  /// `BEGIN`..`COMMIT`/`ROLLBACK` span and runs [f] against it.
  ///
  /// Inside [f], use the `conn` handed in. A [writer]/[reader] call made from
  /// within [f] acquires a SEPARATE pooled connection and runs autocommit
  /// OUTSIDE this transaction — it does not join it (unlike keta_sqlite, which
  /// runs it on the one serialized connection). On a small writer pool that
  /// second acquire can even self-starve against the connection [f] already
  /// holds, blocking until `acquireTimeout` into an [Unavailable]. See
  /// [Db.transaction] for the cross-adapter rule.
  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) {
    if (_activeTx.contains(Zone.current[_txZoneKey])) {
      throw StateError('transactions do not nest');
    }
    final token = Object();
    return translating(() async {
      final conn = await _writerPool.acquire();
      _activeTx.add(token);
      try {
        // runTx issues BEGIN, commits on a normal return, and on a throw rolls
        // back and rethrows the ORIGINAL error — but only when that error is
        // itself a PgException (package:postgres connection.dart:623-641): a
        // non-PgException error from f, paired with a ROLLBACK that then also
        // fails, is rethrown as the ROLLBACK failure instead, masking the
        // original. That double-failure is narrow enough (the transaction
        // body AND the rollback both have to fail) that this adapter leaves it
        // as the driver's own behavior rather than adding an error-wrapping
        // layer to paper over it. Nesting is guarded above via the zone, so f
        // only ever touches the pinned TxSession.
        return await runZoned(
          () => conn.runTx((tx) => f(_TxConn(tx))),
          zoneValues: {_txZoneKey: token},
        );
      } finally {
        _activeTx.remove(token);
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

  /// A snapshot of both connection pools' accounting right now. See
  /// [RdsPoolStats] and [PoolStats] for field semantics and intended use.
  RdsPoolStats get poolStats =>
      RdsPoolStats(writer: _writerPool.stats, reader: _readerPool.stats);
}

/// A snapshot of [RdsDb]'s writer and reader pools, taken together.
///
/// When no `readerEndpoint`/`readerUrl` was given at construction, [writer]
/// and [reader] are stats of the very same [Pool] (see [RdsDb]'s "pool
/// model"), so the two fields report identical numbers rather than this type
/// pretending there is only one pool to ask about. See [PoolStats] for what
/// each field means and its staleness caveat; this type adds nothing beyond
/// pairing the two snapshots.
class RdsPoolStats {
  const RdsPoolStats({required this.writer, required this.reader});

  /// The writer pool's snapshot — every [transaction] and every `writer`
  /// query/execute checks out from this pool.
  final PoolStats writer;

  /// The reader pool's snapshot — every `reader` query checks out from this
  /// pool. Identical to [writer] when no separate reader endpoint was
  /// configured.
  final PoolStats reader;

  @override
  String toString() => 'RdsPoolStats(writer: $writer, reader: $reader)';

  @override
  bool operator ==(Object other) =>
      other is RdsPoolStats && other.writer == writer && other.reader == reader;

  @override
  int get hashCode => Object.hash(writer, reader);
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
