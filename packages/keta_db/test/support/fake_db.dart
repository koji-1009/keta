import 'package:keta_db/keta_db.dart';

/// An in-memory [Db] that records what `applyMigrations` issues, so tests can
/// assert the migration body and its bookkeeping row are staged inside one
/// transaction and only committed on a clean return.
///
/// It supports exactly the three shapes `applyMigrations` uses — a writer
/// `execute` for the ledger DDL, a reader `query` for applied versions, and a
/// `transaction` wrapping the migration SQL plus the ledger insert — and throws
/// on anything else, so it never silently accepts an unexpected call.
class FakeDb implements Db {
  /// SQL statements that actually committed, in order.
  final List<String> committed = [];

  /// Rows of the simulated `_keta_migrations` table.
  final List<Map<String, Object?>> ledger = [];

  /// When set, an `execute` whose SQL contains this substring throws.
  String? failOn;

  bool _inTx = false;

  @override
  late final DbConn reader = _DirectConn(this);

  @override
  DbConn get writer => reader;

  @override
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f) async {
    if (_inTx) throw StateError('transactions do not nest');
    _inTx = true;
    final staged = <(String, List<Object?>)>[];
    try {
      final result = await f(_StagedConn(this, staged));
      for (final (sql, params) in staged) {
        _commit(sql, params);
      }
      return result;
    } finally {
      _inTx = false;
    }
  }

  void _commit(String sql, List<Object?> params) {
    committed.add(sql);
    if (sql.startsWith('insert into _keta_migrations')) {
      ledger.add({'version': params[0], 'applied_at': params[1]});
    }
  }

  void _check(String sql) {
    if (failOn case final f? when sql.contains(f)) {
      throw StateError('injected failure on: $sql');
    }
  }

  List<Map<String, Object?>> _select(String sql) {
    if (sql == 'select version from _keta_migrations') {
      return [
        for (final row in ledger) {'version': row['version']},
      ];
    }
    throw UnsupportedError('FakeDb got an unexpected query: $sql');
  }

  @override
  Future<void> close() async {}
}

/// Reader/writer connection outside a transaction: `execute` commits directly.
class _DirectConn implements DbConn {
  _DirectConn(this._db);
  final FakeDb _db;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) async => _db._select(sql);

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    _db._check(sql);
    _db._commit(sql, params);
    return 1;
  }
}

/// Transaction connection: `execute` stages the statement so a later throw
/// discards it — mirroring how a real engine rolls the whole transaction back.
class _StagedConn implements DbConn {
  _StagedConn(this._db, this._staged);
  final FakeDb _db;
  final List<(String, List<Object?>)> _staged;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) => throw UnsupportedError('applyMigrations must not query inside a tx');

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    _db._check(sql); // throw before staging: the statement never commits.
    _staged.add((sql, params));
    return 1;
  }
}
