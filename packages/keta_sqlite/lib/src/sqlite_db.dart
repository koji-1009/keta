library;

import 'dart:async';
import 'dart:typed_data';

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
  final Database _db;
  final Object _txZoneKey = Object();
  late final _Conn _conn = _Conn(this);
  Future<void> _tail = Future<void>.value();

  SqliteDb._(this._db);

  /// Opens (creating if absent) the database at [path].
  factory SqliteDb.open(String path) => SqliteDb._(sqlite3.open(path));

  /// Opens a private in-memory database.
  factory SqliteDb.memory() => SqliteDb._(sqlite3.openInMemory());

  @override
  DbConn get reader => _conn;

  @override
  DbConn get writer => _conn;

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) {
    if (Zone.current[_txZoneKey] == true) {
      throw StateError('transactions do not nest');
    }
    return _synchronized(() => runZoned(() async {
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
          }
        }, zoneValues: {_txZoneKey: true}));
  }

  @override
  Future<void> close() async => _db.close();

  /// Runs [action] under the lock, unless already inside this db's transaction
  /// zone (where the lock is held for the whole transaction, so re-locking would
  /// deadlock and is unnecessary).
  Future<T> run<T>(FutureOr<T> Function() action) {
    if (Zone.current[_txZoneKey] == true) return Future.sync(action);
    return _synchronized(action);
  }

  Future<T> _synchronized<T>(FutureOr<T> Function() action) {
    final done = Completer<void>();
    final previous = _tail;
    _tail = done.future;
    return previous.then((_) async {
      try {
        return await action();
      } finally {
        done.complete();
      }
    });
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
  final SqliteDb _db;

  _Conn(this._db);

  @override
  Future<List<Map<String, Object?>>> query(String sql,
          [List<Object?> params = const []]) =>
      _db.run(() => _db.rawQuery(sql, params));

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) =>
      _db.run(() => _db.rawExecute(sql, params));
}

/// Normalizes a raw SQLite value to the [DbConn] contract: BLOBs become
/// `List<int>`; integers, doubles, strings, and nulls pass through as-is.
/// SQLite has no native decimal type — a `decimal`/`numeric` column has REAL
/// affinity and is returned as `double` (see keta_sqlite's deployment note).
Object? _mapValue(Object? value) =>
    value is Uint8List ? value.toList(growable: false) : value;
