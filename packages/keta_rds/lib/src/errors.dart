library;

import 'dart:io' show SocketException;

import 'package:keta/keta.dart' show Conflict, Unavailable;
import 'package:postgres/postgres.dart'
    show PgException, ServerException, Severity;

/// The SQLSTATE codes keta_rds translates into keta's vocabulary. Everything
/// not listed here is the app's own bug (a NOT NULL, CHECK, or FOREIGN KEY
/// violation) and is left exactly as the driver threw it: the 500 it earns is
/// the honest answer, and a 409 would tell the client to retry something that
/// can never succeed. This is the [DbConn] floor — an adapter may translate
/// more, never less.
const uniqueViolation = '23505'; // unique_violation → 409 Conflict
const lockNotAvailable = '55P03'; // lock_not_available (lock_timeout) → 503
const tooManyConnections = '53300'; // too_many_connections → 503
const cannotConnectNow = '57P03'; // cannot_connect_now → 503

/// Runs [action], translating the conditions a caller can act on into keta's
/// sealed exceptions so a handler never imports package:postgres to find out
/// what went wrong (and does not break when the same app is pointed at another
/// engine):
///
/// - a uniqueness violation (SQLSTATE 23505) → [Conflict], the driver's rich
///   message (constraint, table, column, key) carried in `detail` for the
///   operator's logs and withheld from the client by KetaException.toString();
/// - a lock that could not be taken in time (55P03), the server refusing new
///   work (53300 too_many_connections, 57P03 cannot_connect_now), or the
///   server being unreachable (a [SocketException] on connect, or a
///   connection-fatal [PgException]) → [Unavailable] (503).
///
/// A keta exception thrown from within (e.g. the pool's own 503 on
/// acquisition timeout) is already in keta's vocabulary and passes straight
/// through.
Future<T> translating<T>(Future<T> Function() action) async {
  try {
    return await action();
  } on ServerException catch (e) {
    switch (e.code) {
      case uniqueViolation:
        throw Conflict('row already exists', e.toString());
      case lockNotAvailable:
      case tooManyConnections:
      case cannotConnectNow:
        throw Unavailable('database temporarily unavailable', e.toString());
    }
    // Any other server error is the app's own — rethrow it untranslated.
    rethrow;
  } on SocketException catch (e) {
    // The server could not be reached at all (connection refused, DNS, reset).
    throw Unavailable('database unreachable', e.toString());
  } on PgException catch (e) {
    // A non-server PgException with a connection-fatal severity means the
    // socket or handshake died — the server is effectively unreachable. A
    // plain query-level PgException is left alone.
    if (e.severity == Severity.fatal || e.severity == Severity.panic) {
      throw Unavailable('database connection lost', e.toString());
    }
    rethrow;
  }
}
