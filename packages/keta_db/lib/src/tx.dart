library;

import 'package:keta/keta.dart';

import 'db.dart';

/// The key under which [tx] publishes the active transaction connection.
///
/// The published value is a completion-guarded wrapper (see [tx]), never the
/// raw adapter connection, so a query attempted after the transaction ends is a
/// clean [StateError] rather than a write on a returned/committed session.
final Key<DbConn> txConn = Key<DbConn>('tx');

/// Wraps the downstream handler in `env.db.transaction`, publishing the
/// transaction connection under [txConn]. The handler returning normally
/// commits; a thrown error rolls back and propagates.
///
/// tx() must be the INNERMOST middleware around the handler — register it AFTER
/// (inside of) any error-to-response middleware such as `recover()`. If
/// `recover()` runs inside tx(), it converts a thrown error into a normal
/// Response before it reaches tx(), so the transaction sees a clean return and
/// COMMITS the writes of a request that actually failed. Correct order:
/// `app..use(recover())..use(tx())`.
///
/// ## Cost: tx() wraps EVERY request it covers, reads included
///
/// tx() knows nothing about what the handler does — a pure `SELECT` route under
/// tx() still pays a `BEGIN`/`COMMIT` round trip and, for its whole duration,
/// pins one connection from the **writer** pool. That quietly defeats the
/// reader/writer split: reads that could have gone to a replica (or at least to
/// the reader pool) instead consume writer capacity, so the effective ceiling
/// on concurrent requests collapses to the writer pool's `maxConnections`. A
/// slow handler (an external call, a large streamed body) holds that writer
/// connection the entire time.
///
/// So do NOT mount tx() app-wide. Scope it to the routes that actually write,
/// with a group:
///
/// ```dart
/// app
///   ..use(recover())
///   ..get('/things', listThings) // reads: no tx(), free to use the reader
///   ..group('/things', (g) => g..use(tx())..post('/', createThing));
/// ```
///
/// Read routes then reach the database directly through `env.db.reader`;
/// only the write group pays for a transaction.
///
/// ## Cost: the transaction connection dies with the handler's return
///
/// The value published under [txConn] is a completion guard, not the adapter's
/// raw connection: the instant `next(c)` returns (or throws), the transaction
/// commits (or rolls back) and the guard is tripped. Any `query`/`execute` on it
/// after that — from a **streaming response body** whose callback runs after the
/// handler returned, or a closure that captured the connection and outlived the
/// request — throws a `StateError('transaction already completed')` instead of
/// running on a session that has been committed and whose connection is already
/// back in the pool (where the next request could be mid-query on it). If a
/// streaming body needs the database, it must open its own `env.db` access; it
/// cannot borrow the request's transaction.
Middleware<E> tx<E extends HasDb>() => (Context<E> c, Handler<E> next) {
  return c.env.db.transaction((conn) async {
    final guard = _CompletedGuard(conn);
    c.set(txConn, guard);
    try {
      return await next(c);
    } finally {
      // Runs on BOTH paths: a normal return (→ COMMIT) and a throw (→ ROLLBACK).
      // Either way the session is finished the moment we leave the callback, so
      // the guard must refuse from here on — see the class doc.
      guard._close();
    }
  });
};

/// A [DbConn] that forwards to the transaction connection until the transaction
/// completes, then refuses every call.
///
/// [tx] publishes THIS under [txConn], never the raw connection, so a session
/// that has already COMMITTED or ROLLED BACK cannot still be queried. On a
/// pooled adapter (keta_rds) the underlying connection is handed back to the
/// pool the instant the transaction ends, so a late query would run — silently —
/// on a connection another request may already own; on a single-writer adapter
/// the lock is released and the write would land outside any transaction.
/// Neither is the isolation the caller believes they still have, so both become
/// a loud [StateError] instead. The failure is a programming error (a leaked
/// connection, a streaming body reaching back into the request's transaction),
/// so it is thrown synchronously.
class _CompletedGuard implements DbConn {
  _CompletedGuard(this._conn);

  final DbConn _conn;
  bool _completed = false;

  void _close() => _completed = true;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> params = const [],
  ]) {
    if (_completed) throw StateError('transaction already completed');
    return _conn.query(sql, params);
  }

  @override
  Future<int> execute(String sql, [List<Object?> params = const []]) {
    if (_completed) throw StateError('transaction already completed');
    return _conn.execute(sql, params);
  }
}
