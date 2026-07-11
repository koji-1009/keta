import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';

/// The application environment: the constructor graph that carries the app's
/// dependencies. keta reaches [log] and [close] structurally; keta_db reaches
/// [db].
class Env implements HasLog, HasDb, Disposable {
  @override
  final Db db;
  @override
  final Log log;

  Env(this.db, this.log);

  static Future<Env> boot() async => Env(SqliteDb.open('app.db'), StdoutLog());

  @override
  Future<void> close() => db.close();
}
