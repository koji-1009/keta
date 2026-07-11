library;

import 'package:keta/keta.dart';

import 'db.dart';

/// The key under which [tx] publishes the active transaction connection.
final Key<DbConn> txConn = Key<DbConn>('tx');

/// Wraps the downstream handler in `env.db.transaction`, publishing the
/// transaction connection under [txConn]. The handler returning normally
/// commits; a thrown error rolls back and propagates. Commit/rollback timing is
/// the [Db] implementation's call.
Middleware<E> tx<E extends HasDb>() => (Context<E> c, Handler<E> next) {
      return c.env.db.transaction((conn) async {
        c.set(txConn, conn);
        return next(c);
      });
    };
