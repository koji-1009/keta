library;

import 'dart:io' show SocketException;

import 'package:keta/keta.dart'
    show Conflict, TransientFailure, Unavailable, UnprocessableEntity;
import 'package:postgres/postgres.dart'
    show PgException, ServerException, Severity;

/// The SQLSTATE codes keta_rds translates into keta's vocabulary, grouped by the
/// keta exception they become. This is the [DbConn] floor for a SQLSTATE-classed
/// engine — an adapter may translate more, never less. Everything not listed
/// here (a syntax error, a data-type mismatch, an undefined column, …) is the
/// app's own bug and is left exactly as the driver threw it: the 500 it earns is
/// the honest answer.
///
/// The three integrity violations split by who is at fault and what a retry
/// would achieve:
///
/// - a *uniqueness* collision (23505) or a *foreign-key* violation (23503) is a
///   conflict with the current state of other rows — a duplicate key, or a
///   parent that is absent or still referenced. The same request may succeed
///   once that state changes, so it is a [Conflict] (409), not a bare 500.
/// - a *NOT NULL* (23502) or *CHECK* (23514) violation is a well-formed request
///   carrying a value the schema rejects on its own terms — no other row is
///   involved and no retry of the identical request can pass. That is
///   [UnprocessableEntity] (422): client-caused, and permanently so for this
///   input.
/// - a *serialization failure* (40001) or *deadlock* (40P01) is neither party's
///   data being wrong: two healthy transactions raced and the engine aborted
///   this one to break the tie. Replaying the identical request is exactly the
///   right move — so it is a [TransientFailure] (503). keta does not retry it
///   for you (idempotency is unknowable here); the type exists so the app can.
const uniqueViolation = '23505'; // unique_violation → 409 Conflict
const foreignKeyViolation = '23503'; // foreign_key_violation → 409 Conflict
const notNullViolation =
    '23502'; // not_null_violation → 422 UnprocessableEntity
const checkViolation = '23514'; // check_violation → 422 UnprocessableEntity
const serializationFailure = '40001'; // serialization_failure → 503 Transient
const deadlockDetected = '40P01'; // deadlock_detected → 503 TransientFailure
const lockNotAvailable = '55P03'; // lock_not_available (lock_timeout) → 503
const tooManyConnections = '53300'; // too_many_connections → 503
const cannotConnectNow = '57P03'; // cannot_connect_now → 503
const adminShutdown = '57P01'; // admin_shutdown → 503
const crashShutdown = '57P02'; // crash_shutdown → 503

/// The two verbatim messages package:postgres constructs when the socket dies
/// mid-session. Both are raised with the driver's DEFAULT (error) severity even
/// though the connection is already gone, and neither carries a SQLSTATE — so
/// the only thing that distinguishes "the socket died" from an ordinary
/// client-side PgException is the message text itself (see [translating] and
/// the driver-source citations there). Matching by string is therefore
/// unavoidable, and it is brittle: a driver patch release that rewords either
/// line would silently downgrade a mid-session disconnect from a 503 to a raw
/// 500. `test/driver_message_canary_test.dart` pins these literals against the
/// installed driver source so `dart pub upgrade` breaking the match fails CI
/// loudly instead. Keep the two in lockstep: this is the ONLY definition, and
/// both the runtime match below and the canary read it from here.
const socketErrorPrefix = 'Socket error: '; // connection.dart:465
const socketClosedMessage =
    'The underlying socket to Postgres has been closed unexpectedly.'; // :495

/// Runs [action], translating the conditions a caller can act on into keta's
/// sealed exceptions so a handler never imports package:postgres to find out
/// what went wrong (and does not break when the same app is pointed at another
/// engine):
///
/// - a uniqueness (23505) or foreign-key (23503) violation → [Conflict], the
///   driver's rich message (constraint, table, column, key) carried in `detail`
///   for the operator's logs and withheld from the client by
///   KetaException.toString();
/// - a NOT NULL (23502) or CHECK (23514) violation → [UnprocessableEntity]
///   (422): the request is well-formed but carries a value the schema rejects;
/// - a serialization failure (40001) or deadlock (40P01) → [TransientFailure]
///   (503): the transaction lost a concurrency race and retrying the identical
///   request is reasonable (keta does not retry for you — see [TransientFailure]);
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
      case foreignKeyViolation:
        throw Conflict(
          'related row is missing or still referenced',
          e.toString(),
        );
      case notNullViolation:
        throw UnprocessableEntity('a required value was missing', e.toString());
      case checkViolation:
        throw UnprocessableEntity(
          'a value failed a check constraint',
          e.toString(),
        );
      case serializationFailure:
      case deadlockDetected:
        throw TransientFailure(
          'the transaction conflicted; retry the request',
          e.toString(),
        );
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
        message.startsWith(socketErrorPrefix) || message == socketClosedMessage;
    if (e.severity == Severity.fatal ||
        e.severity == Severity.panic ||
        isSocketDeath) {
      throw Unavailable('database connection lost', e.toString());
    }
    rethrow;
  }
}
