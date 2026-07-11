library;

import 'dart:async';
import 'dart:typed_data';

import 'package:keta_db/keta_db.dart';
import 'package:sqlite3/sqlite3.dart';

/// A [Db] backed by package:sqlite3. SQLite is single-writer, so [reader] and
/// [writer] are the same connection, and transactions cannot nest.
class SqliteDb implements Db {
  final Database _db;
  late final _SqliteConn _conn;
  bool _inTransaction = false;

  SqliteDb._(this._db) {
    _conn = _SqliteConn(_db);
  }

  /// Opens (creating if absent) the database at [path].
  factory SqliteDb.open(String path) => SqliteDb._(sqlite3.open(path));

  /// Opens a private in-memory database.
  factory SqliteDb.memory() => SqliteDb._(sqlite3.openInMemory());

  @override
  DbConn get reader => _conn;

  @override
  DbConn get writer => _conn;

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) async {
    if (_inTransaction) {
      throw StateError('transactions do not nest');
    }
    _inTransaction = true;
    _db.execute('BEGIN');
    try {
      final result = await f(_conn);
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  @override
  Future<void> close() async => _db.close();
}

class _SqliteConn implements DbConn {
  final Database _db;

  _SqliteConn(this._db);

  @override
  Future<List<Map<String, Object?>>> query(String sql,
      [List<Object?> params = const []]) async {
    final result = _db.select(sql, params);
    final columns = result.columnNames;
    return [
      for (final row in result)
        {for (final column in columns) column: _mapValue(row[column])},
    ];
  }

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    _db.execute(sql, params);
    return _db.updatedRows;
  }
}

/// Normalizes a raw SQLite value to the [DbConn] contract: BLOBs become
/// `List<int>`; integers, doubles, strings, and nulls pass through as-is.
Object? _mapValue(Object? value) =>
    value is Uint8List ? value.toList(growable: false) : value;
