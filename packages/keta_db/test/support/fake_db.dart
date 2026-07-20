/// Shared support fixture: the single-sourced FakeDb used by keta_db's
/// migration-runner tests (apply/verify/checksum/legacy-ledger).
library;

import 'package:keta_db/keta_db.dart';

/// An in-memory [Db] that records what `applyMigrations` issues, so tests can
/// assert the migration body and its bookkeeping row are staged inside one
/// transaction and only committed on a clean return.
///
/// It supports exactly the shapes the migration runner uses — a writer
/// `execute` for the ledger DDL (and the legacy-upgrade `ALTER`), a `query` for
/// applied versions/checksums, and a `transaction` wrapping the migration SQL
/// plus the ledger insert — and throws on anything else, so it never silently
/// accepts an unexpected call.
///
/// The reader and writer are distinct connection objects that tag every query
/// with the side it came in on ([queries]); the runner routes all ledger reads
/// through the writer (replica-lag safety), and tests assert on that here.
class FakeDb implements Db {
  /// [legacyLedger] pre-seeds rows written before the checksum column existed
  /// (NULL checksum) and marks the ledger as lacking that column, so the runner
  /// must `ALTER TABLE ... ADD COLUMN` before it can read checksums — the
  /// old-deployment upgrade path.
  FakeDb({List<String> legacyLedger = const []}) {
    if (legacyLedger.isNotEmpty) {
      hasChecksumColumn = false;
      for (final version in legacyLedger) {
        ledger.add({
          'version': version,
          'applied_at': 'legacy',
          'checksum': null,
        });
      }
    }
  }

  /// SQL statements that actually committed, in order.
  final List<String> committed = [];

  /// Rows of the simulated `_keta_migrations` table.
  final List<Map<String, Object?>> ledger = [];

  /// Every query issued, as `(side, sql)` — 'reader' or 'writer'. Ledger reads
  /// must all be 'writer'.
  final List<(String side, String sql)> queries = [];

  /// Whether the simulated ledger has the `checksum` column. A legacy ledger
  /// starts without it, so a `select ... checksum ...` throws until the runner
  /// adds it with `ALTER TABLE`.
  bool hasChecksumColumn = true;

  /// When set, an `execute` whose SQL contains this substring throws.
  String? failOn;

  /// When set, any `query` throws this instead of running — simulating a
  /// broken/unreachable connection (as opposed to a merely-missing ledger
  /// table).
  Error? unreachable;

  bool _inTx = false;

  @override
  late final DbConn reader = _DirectConn(this, 'reader');

  @override
  late final DbConn writer = _DirectConn(this, 'writer');

  @override
  DbCapabilities capabilities = const DbCapabilities(
    nativeBool: true,
    exactDecimal: true,
    typedTemporal: true,
  );

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
      ledger.add({
        'version': params[0],
        'applied_at': params[1],
        'checksum': params.length > 2 ? params[2] : null,
      });
    } else if (sql.contains('add column checksum')) {
      hasChecksumColumn = true;
    }
  }

  void _check(String sql) {
    if (failOn case final f? when sql.contains(f)) {
      throw StateError('injected failure on: $sql');
    }
  }

  List<Map<String, Object?>> _select(String side, String sql) {
    queries.add((side, sql));
    if (unreachable case final e?) throw e;
    if (sql == 'select 1') return const [];
    if (sql == 'select version from _keta_migrations') {
      return [
        for (final row in ledger) {'version': row['version']},
      ];
    }
    if (sql == 'select version, checksum from _keta_migrations') {
      // A legacy ledger has no checksum column: the read fails until the runner
      // adds it, mirroring how sqlite3/PostgreSQL reject an unknown column.
      if (!hasChecksumColumn) {
        throw StateError('no such column: checksum');
      }
      return [
        for (final row in ledger)
          {'version': row['version'], 'checksum': row['checksum']},
      ];
    }
    throw UnsupportedError('FakeDb got an unexpected query: $sql');
  }

  @override
  Future<void> close() async {}
}

/// Reader/writer connection outside a transaction: `execute` commits directly.
class _DirectConn implements DbConn {
  _DirectConn(this._db, this._side);
  final FakeDb _db;
  final String _side;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) async => _db._select(_side, sql);

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
