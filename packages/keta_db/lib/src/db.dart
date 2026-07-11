library;

/// A single database connection.
///
/// The type-mapping contract every implementation must honor: `INTEGER`
/// columns come back as [int], floating-point as [double], booleans as [bool],
/// timestamps as ISO 8601 [String]s, and — crucially — numeric/decimal columns
/// as [String], never [double], so exact precision is preserved.
abstract interface class DbConn {
  /// Runs a query and returns its rows as column-name maps.
  Future<List<Map<String, Object?>>> query(String sql,
      [List<Object?> params = const []]);

  /// Runs a statement and returns the number of affected rows.
  Future<int> execute(String sql, [List<Object?> params = const []]);
}

/// A database, split into a read connection and a write connection (the same
/// connection on single-writer engines like SQLite).
abstract interface class Db {
  DbConn get reader;
  DbConn get writer;

  /// Runs [f] in a transaction: a normal return commits, a thrown error rolls
  /// back and rethrows. Transactions do not nest — an inner call is a
  /// [StateError].
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f);

  Future<void> close();
}

/// An environment that owns a [Db]. Implement it so `tx()` and the migration
/// tools can reach the database without the framework learning DB vocabulary.
abstract interface class HasDb {
  Db get db;
}
