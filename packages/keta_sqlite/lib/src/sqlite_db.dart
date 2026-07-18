library;

import 'dart:async';
import 'dart:typed_data';

import 'package:keta/keta.dart' show Conflict, Unavailable;
import 'package:keta_db/keta_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// A [Db] backed by package:sqlite3.
///
/// SQLite is single-writer, so every access to the one connection is serialized
/// through an async lock: a query/execute takes the lock for its call, and a
/// [transaction] holds it across the whole `BEGIN`..`COMMIT`/`ROLLBACK`,
/// spanning the awaits inside `f`. This makes concurrent requests correct
/// (no interleaving into an open transaction, no spurious "nesting" error) —
/// serialization matches SQLite's semantics rather than compromising them.
///
/// **Stated constraint**: sqlite3 calls are synchronous FFI on the serving
/// isolate. A slow query blocks that isolate's entire event loop — every other
/// request it is handling, DB-bound or not, stalls until the call returns.
/// This is a property of embedding SQLite in-process, not a bug; the
/// mitigations are `serve(isolates: n)` (so one slow query does not stall the
/// whole process) and keeping queries indexed and small. [SqliteDb.open]'s
/// [lockTimeout] doc states this constraint's sharpest edge: the
/// `busy_timeout` PRAGMA's own retry is one such "slow query".
class SqliteDb implements Db {
  SqliteDb._(this._db, this._lockTimeout);

  /// Opens (creating if absent) the database at [path]. [lockTimeout] bounds how
  /// long a statement waits to acquire the single-writer lock (default 30s), and
  /// is also used as this connection's `busy_timeout` PRAGMA (see [_open]).
  ///
  /// **Stated trade-off**: `busy_timeout`'s retry loop spins inside sqlite3's
  /// synchronous FFI call (see the class-level constraint above), so a
  /// cross-process writer contending for the file lock blocks this connection's
  /// entire isolate — every request it serves, not only the one waiting on the
  /// lock — for up to [lockTimeout], not just the one call. Measured: a 500ms
  /// contention window fired zero event-loop timers on the blocked isolate.
  /// Deployments expecting cross-process writers should keep [lockTimeout]
  /// modest rather than relying on its 30s default. [transaction] opens with
  /// `BEGIN IMMEDIATE`, so a write transaction takes the lock (and does its
  /// bounded `busy_timeout` wait) at `BEGIN` rather than on first upgrade.
  ///
  /// **[wal]** (opt-in, default off) switches this file to WAL journaling:
  /// readers no longer block the single writer, and the writer no longer blocks
  /// readers — across processes, not just within this isolate — which is the
  /// win under the cross-process contention this adapter targets. The cost:
  /// WAL keeps a shared-memory index (`-wal`/`-shm` sidecar files) that every
  /// connection to the database must reach through the *same host's*
  /// filesystem, so a WAL database cannot live on a network filesystem (NFS);
  /// [_enableWal] reads the mode back and fails loudly if the switch did not
  /// take. Left off, the file uses SQLite's default rollback journal — the
  /// prior behavior, unchanged. WAL is a no-op for [memory] (see there).
  factory SqliteDb.open(
    String path, {
    Duration lockTimeout = const Duration(seconds: 30),
    bool wal = false,
  }) =>
      SqliteDb._(_open(sqlite3.open(path), lockTimeout, wal: wal), lockTimeout);

  /// Opens a private in-memory database. See [open] for [lockTimeout].
  ///
  /// [wal] is accepted for a uniform surface but is a deliberate no-op here: an
  /// in-memory database has no file for WAL's `-wal`/`-shm` sidecar index, and
  /// sqlite3 will not switch it — `PRAGMA journal_mode = WAL` silently returns
  /// `memory` and the mode stays `memory` (measured). Rather than issue a pragma
  /// whose result we would have to special-case, [memory] never asks for WAL, so
  /// `memory(wal: true)` opens a normal in-memory database.
  factory SqliteDb.memory({
    Duration lockTimeout = const Duration(seconds: 30),
    bool wal = false,
  }) => SqliteDb._(_open(sqlite3.openInMemory(), lockTimeout), lockTimeout);

  /// Applies the PRAGMA contract every connection opens with, then returns it.
  ///
  /// `foreign_keys = ON`: sqlite3 defaults this OFF for backwards compatibility
  /// with pre-3.6.19 databases — a default this framework has no reason to
  /// inherit. Without it, a migration that declares `FOREIGN KEY` constraints
  /// gets silent non-enforcement, which is worse than not declaring the
  /// constraint at all (the schema documents an invariant nothing checks).
  ///
  /// `busy_timeout`: bounds how long sqlite3's own retry loop waits for a
  /// cross-connection (cross-process or cross-isolate) lock before returning
  /// `SQLITE_BUSY`, mirroring the in-process queue's [lockTimeout] bound — a
  /// second connection on the same file should wait no longer than a same-
  /// process caller does before getting a loud, bounded failure.
  static Database _open(Database db, Duration lockTimeout, {bool wal = false}) {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA busy_timeout = ${lockTimeout.inMilliseconds}');
    if (wal) _enableWal(db);
    return db;
  }

  /// Switches [db] to WAL journaling, failing loudly if the switch did not take.
  ///
  /// `PRAGMA journal_mode = WAL` returns the mode actually in force, not an
  /// error. On a file-backed database that is `wal`; but if the filesystem
  /// cannot host WAL's shared-memory index — a network filesystem such as NFS,
  /// where WAL's requirement that all connections share one host's memory
  /// cannot hold — sqlite quietly declines and returns the *old* mode. Reading
  /// it back and throwing turns that into a startup failure, rather than
  /// running under the false belief that cross-process readers no longer block
  /// the writer when they still do.
  static void _enableWal(Database db) {
    final mode = db.select('PRAGMA journal_mode = WAL').rows.first.first;
    if (mode != 'wal') {
      throw StateError(
        'requested WAL journal mode but sqlite reports "$mode"; WAL needs a '
        'same-host filesystem for its -wal/-shm index (no NFS)',
      );
    }
  }

  final Database _db;
  final Object _txZoneKey = Object();
  // The token of the transaction currently executing, or null between them. Each
  // transaction stamps a fresh token into its zone; the no-relock shortcut fires
  // only when the caller's zone carries the *active* token — so a zone captured
  // inside one transaction and reused after it (or during a different one) does
  // not bypass the lock and dirty-read another open transaction.
  Object? _currentTx;
  // How long a call may wait to acquire the serialization lock before giving up
  // with a 503. A transaction that awaits unbounded work would otherwise hold
  // the lock forever and hang every other DB access silently; this bounds the
  // wait so the failure is loud (503 + log) instead of a deadlock.
  final Duration _lockTimeout;
  late final _Conn _conn = _Conn(this);
  Future<void> _tail = Future<void>.value();

  @override
  DbConn get reader => _conn;

  @override
  DbConn get writer => _conn;

  /// Runs [f] inside a single write transaction, opened with `BEGIN IMMEDIATE`.
  ///
  /// The default `BEGIN` starts a *deferred* transaction that takes no lock
  /// until the first statement, and only a read lock until the first write — so
  /// a read-then-write body (the common `SELECT` current row, then `UPDATE`)
  /// asks to upgrade a read lock to a write lock while another connection holds
  /// the write lock. SQLite cannot honor `busy_timeout` on that upgrade: waiting
  /// would risk deadlock (two readers each refusing to release), so it returns
  /// `SQLITE_BUSY` *immediately*, bypassing the very bounded-wait this adapter
  /// relies on. `BEGIN IMMEDIATE` takes the write lock up front, at `BEGIN`,
  /// where `busy_timeout` does apply — the contending caller then does its
  /// bounded wait and gets a loud, timed `Unavailable`, not a surprise busy on
  /// the first `UPDATE`. Every [transaction] is a write transaction here (there
  /// is no read-only variant), so paying the write lock at `BEGIN` costs
  /// nothing a deferred read would have saved.
  ///
  /// One consequence worth naming: a caller that reaches for [transaction]
  /// purely for a consistent multi-statement **read** (no write in the body at
  /// all) still takes the write lock at `BEGIN`, and so still serializes behind
  /// every other writer — even with [SqliteDb.open]'s `wal: true`, where a
  /// plain read normally would not block on the writer at all.
  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) {
    if (_inActiveTxZone) {
      throw StateError('transactions do not nest');
    }
    final token = Object();
    return _synchronized(
      () => runZoned(() async {
        _currentTx = token;
        _db.execute('BEGIN IMMEDIATE');
        try {
          final result = await f(_conn);
          _db.execute('COMMIT');
          return result;
        } catch (_) {
          // Never let a ROLLBACK failure (e.g. the txn was already closed)
          // mask the original error.
          try {
            _db.execute('ROLLBACK');
          } catch (_) {}
          rethrow;
        } finally {
          _currentTx = null;
        }
      }, zoneValues: {_txZoneKey: token}),
    );
  }

  @override
  Future<void> close() => _synchronized(() => _db.close());

  /// Whether the current zone belongs to the transaction that is executing right
  /// now (identity, not just "some transaction ran here once").
  bool get _inActiveTxZone =>
      _currentTx != null && identical(Zone.current[_txZoneKey], _currentTx);

  /// Runs [action] under the lock, unless already inside this db's *active*
  /// transaction zone (where the lock is held for the whole transaction, so
  /// re-locking would deadlock and is unnecessary).
  Future<T> run<T>(FutureOr<T> Function() action) {
    if (_inActiveTxZone) return Future.sync(action);
    return _synchronized(action);
  }

  Future<T> _synchronized<T>(FutureOr<T> Function() action) {
    final done = Completer<void>();
    final previous = _tail;
    _tail = done.future;
    return _acquireThenRun(previous, done, action);
  }

  Future<T> _acquireThenRun<T>(
    Future<void> previous,
    Completer<void> done,
    FutureOr<T> Function() action,
  ) async {
    try {
      await previous.timeout(_lockTimeout);
    } on TimeoutException {
      // Give up our slot without jumping the queue: successors still wait for
      // the holder that is actually running, then run in order.
      unawaited(previous.whenComplete(done.complete));
      throw const Unavailable(
        'database busy: could not acquire the lock in time',
      );
    }
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  List<Map<String, Object?>> rawQuery(String sql, List<Object?> params) =>
      _translating(() {
        final result = _db.select(sql, params);
        final columns = result.columnNames;
        return [
          for (final row in result)
            {for (final column in columns) column: _mapValue(row[column])},
        ];
      });

  int rawExecute(String sql, List<Object?> params) => _translating(() {
    _db.execute(sql, params);
    return _db.updatedRows;
  });
}

/// The extended codes that mean "this row already exists", and only those.
///
/// Deliberately not every SQLITE_CONSTRAINT: a NOT NULL, CHECK, FOREIGN KEY or
/// TRIGGER violation is the app's own data being wrong. That is a bug, and the
/// 500 it already earns is the honest answer — a 409 would tell the client to
/// retry something that can never succeed.
const _uniquenessViolations = {
  SqlExtendedError.SQLITE_CONSTRAINT_PRIMARYKEY,
  SqlExtendedError.SQLITE_CONSTRAINT_UNIQUE,
  SqlExtendedError.SQLITE_CONSTRAINT_ROWID,
};

/// Runs [action], translating the driver's uniqueness violations into keta's
/// [Conflict], and a cross-connection lock timeout into [Unavailable].
///
/// Without this the app has to catch `SqliteException` and match code 1555 to
/// answer 409 — which means importing package:sqlite3 into a handler, coupling
/// it to this engine, and breaking the moment the same app runs on another one.
/// The Db contract is driver-agnostic, so the driver's vocabulary stops here.
/// This is the same move the lock timeout above already makes with [Unavailable];
/// only uniqueness had been left untranslated.
T _translating<T>(T Function() action) {
  try {
    return action();
  } on SqliteException catch (e) {
    if (e.resultCode == SqlError.SQLITE_CONSTRAINT &&
        _uniquenessViolations.contains(e.extendedResultCode)) {
      // The driver's message names the table and column that collided. That is
      // the operator's to see and the client's to be spared, which is what
      // `detail` is for: recover() logs it, and KetaException.toString() keeps
      // it out of the response.
      throw Conflict('row already exists', e.message);
    }
    if (e.resultCode == SqlError.SQLITE_BUSY) {
      // The in-process lock (above) only ever serializes callers on *this*
      // SqliteDb; SQLITE_BUSY means a *different* connection — another
      // process, or another isolate that opened the same file — held the
      // lock past our `busy_timeout`. Same "lock unobtainable in time"
      // condition as the in-process queue's Unavailable, just crossing a
      // connection boundary the queue cannot see.
      throw const Unavailable(
        'database busy: could not acquire the lock in time',
      );
    }
    rethrow;
  }
}

class _Conn implements DbConn {
  _Conn(this._db);
  final SqliteDb _db;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) => _db.run(() => _db.rawQuery(sql, params));

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) =>
      _db.run(() => _db.rawExecute(sql, params));
}

/// Normalizes a raw SQLite value: BLOBs become a fixed-length `List<int>`;
/// integers, doubles, strings, and nulls pass through as-is. SQLite has no
/// native decimal type — a `decimal`/`numeric` column has NUMERIC affinity, so
/// the same column can come back as [int] (for a losslessly-integral value such
/// as `5.0`) or [double] (for `5.5`), and is never an exact decimal String.
/// Store exact decimals (money) as TEXT if you need them preserved.
Object? _mapValue(Object? value) =>
    value is Uint8List ? value.toList(growable: false) : value;
