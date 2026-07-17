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
const adminShutdown = '57P01'; // admin_shutdown → 503
const crashShutdown = '57P02'; // crash_shutdown → 503

/// Runs [action], translating the conditions a caller can act on into keta's
/// sealed exceptions so a handler never imports package:postgres to find out
/// what went wrong (and does not break when the same app is pointed at another
/// engine):
///
/// - a uniqueness violation (SQLSTATE 23505) → [Conflict], the driver's rich
///   message (constraint, table, column, key) carried in `detail` for the
///   operator's logs and withheld from the client by KetaException.toString();
/// - a lock that could not be taken in time (55P03), the server refusing new
///   work or tearing down the session (53300 too_many_connections, 57P03
///   cannot_connect_now, 57P01 admin_shutdown, 57P02 crash_shutdown), or the
///   server being unreachable (a [SocketException] on connect, or the socket
///   dying mid-session) → [Unavailable] (503).
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
      case adminShutdown:
      case crashShutdown:
        throw Unavailable('database temporarily unavailable', e.toString());
    }
    // Any other server error is the app's own — rethrow it untranslated.
    rethrow;
  } on SocketException catch (e) {
    // The server could not be reached at all (connection refused, DNS, reset).
    throw Unavailable('database unreachable', e.toString());
  } on PgException catch (e) {
    // Every error the *server* reports arrives as a [ServerException] (built
    // from an ErrorResponse's fields by buildExceptionFromErrorFields, called
    // only from the ErrorResponseMessage branch of _handleMessage —
    // package:postgres lib/src/v3/connection.dart:501-524/1386) and is caught
    // by the `on ServerException` clause above, never here. So whatever a
    // plain PgException carries here is connection- or client-side.
    //
    // It is tempting to treat every such PgException as a dead connection,
    // but that is not true: the driver also throws a plain PgException for
    // caller-side encoding failures with the connection perfectly healthy —
    // e.g. "Could not infer type of value" (lib/src/types/type_registry.dart:293)
    // and "Unable to parse TsQuery" (lib/src/types/text_search.dart:279). Those
    // must fall through to the caller's own bug, the same as an untranslated
    // ServerException above.
    //
    // What genuinely means "the socket died" is a connection-fatal severity
    // (fatal/panic — BadCertificateException and the like), or one of the two
    // exact messages the driver uses for socket death mid-session, which it
    // constructs with the default `error` severity even though the connection
    // is gone: `_close(true, PgException('Socket error: $e'), ...)` and the
    // "underlying socket ... closed unexpectedly" case raised from
    // `_socketClosed` (connection.dart:465, :491-499).
    final message = e.message;
    final isSocketDeath =
        message.startsWith('Socket error: ') ||
        message ==
            'The underlying socket to Postgres has been closed unexpectedly.';
    if (e.severity == Severity.fatal ||
        e.severity == Severity.panic ||
        isSocketDeath) {
      throw Unavailable('database connection lost', e.toString());
    }
    rethrow;
  }
}
