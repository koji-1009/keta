library;

import 'package:keta/keta.dart';

import 'db.dart';

/// The key under which [tx] publishes the active transaction connection.
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
Middleware<E> tx<E extends HasDb>() => (Context<E> c, Handler<E> next) {
      return c.env.db.transaction((conn) async {
        c.set(txConn, conn);
        return next(c);
      });
    };
