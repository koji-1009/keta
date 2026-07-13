library;

import 'dart:async';
import 'dart:typed_data';

import 'package:keta/keta.dart' show Unavailable;
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
class SqliteDb implements Db {
  SqliteDb._(this._db, this._lockTimeout);

  /// Opens (creating if absent) the database at [path]. [lockTimeout] bounds how
  /// long a statement waits to acquire the single-writer lock (default 30s).
  factory SqliteDb.open(
    String path, {
    Duration lockTimeout = const Duration(seconds: 30),
  }) => SqliteDb._(sqlite3.open(path), lockTimeout);

  /// Opens a private in-memory database. See [open] for [lockTimeout].
  factory SqliteDb.memory({
    Duration lockTimeout = const Duration(seconds: 30),
  }) => SqliteDb._(sqlite3.openInMemory(), lockTimeout);
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

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) {
    if (_inActiveTxZone) {
      throw StateError('transactions do not nest');
    }
    final token = Object();
    return _synchronized(
      () => runZoned(() async {
        _currentTx = token;
        _db.execute('BEGIN');
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

  List<Map<String, Object?>> rawQuery(String sql, List<Object?> params) {
    final result = _db.select(sql, params);
    final columns = result.columnNames;
    return [
      for (final row in result)
        {for (final column in columns) column: _mapValue(row[column])},
    ];
  }

  int rawExecute(String sql, List<Object?> params) {
    _db.execute(sql, params);
    return _db.updatedRows;
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
