library;

/// A single database connection.
///
/// Values come back in the engine's storage classes, mapped by the concrete
/// adapter. The keta_sqlite adapter returns `INTEGER` as [int], `REAL` as
/// [double], `TEXT` as [String], `BLOB` as `List<int>`, and `NULL` as `null`.
/// SQLite has no dedicated decimal/boolean/timestamp storage: a `numeric`/
/// `decimal` column has NUMERIC affinity and comes back as [int] or [double]
/// (never an exact decimal String), a boolean is an [int] `0`/`1`, and a
/// timestamp is whatever you stored (an ISO 8601 [String] if that is what you
/// wrote). Store money and other exact decimals as [String] for exact
/// round-tripping.
/// A connection's query surface.
///
/// Errors are keta's, not the engine's. An adapter translates the conditions a
/// caller can act on into keta's sealed `KetaException` family, so a handler
/// never imports a driver package to find out what went wrong, and does not
/// break when the same app is pointed at a different engine.
///
/// The floor every adapter must honour, on every engine:
///
/// - a uniqueness violation (duplicate primary key or unique index) → `Conflict`
/// - the database unreachable, or its lock unobtainable in time → `Unavailable`
///
/// Adapters over an engine that classifies errors by SQL-standard SQLSTATE (the
/// PostgreSQL family) must additionally honour, because that engine reports each
/// as a distinct, actionable condition:
///
/// - a foreign-key violation (a parent absent or still referenced) → `Conflict`
/// - a NOT NULL or CHECK violation (a well-formed request the schema rejects on
///   its own terms) → `UnprocessableEntity`
/// - a serialization failure or deadlock (two healthy transactions raced and one
///   was aborted to break the tie) → `TransientFailure`
///
/// The second tier is scoped to SQLSTATE-classed engines on purpose: an engine
/// with a different error model or concurrency model does not necessarily raise
/// these as distinct conditions (SQLite, single-writer, has no serialization
/// failure or deadlock to translate at all), so binding it to the same list
/// would demand a mapping it cannot honestly produce.
///
/// Anything else is the app's own bug and is left as the driver threw it, where
/// the 500 and its log are the honest answer. This is a floor, not a ceiling:
/// an adapter may translate more, never less.
abstract interface class DbConn {
  /// Runs a query and returns its rows as column-name maps.
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]);

  /// Runs a statement and returns the number of rows it changed
  /// (`sqlite3_changes`). Meaningful only for `INSERT`/`UPDATE`/`DELETE`; for
  /// DDL or a `SELECT` the value carries over from the last DML, so don't branch
  /// on it there.
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
  ///
  /// On a single-writer engine the connection lock is held for the whole
  /// transaction, across every await inside [f]. Do NOT await unbounded external
  /// work (a slow HTTP call, an uncompleted future) inside [f]: it holds the
  /// lock and blocks every other database access for the process until it
  /// returns. Keep transactions short and DB-bound.
  Future<T> transaction<T>(Future<T> Function(DbConn conn) f);

  Future<void> close();
}

/// An environment that owns a [Db]. Implement it so `tx()` and the migration
/// tools can reach the database without the framework learning DB vocabulary.
abstract interface class HasDb {
  Db get db;
}
