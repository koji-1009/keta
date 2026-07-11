/// keta_sqlite — a thin [Db] adapter over package:sqlite3, supporting on-disk
/// and in-memory databases.
///
/// Provisional: the native `libsqlite3` is taken from the system. Until a
/// source-pinned build hook bundles it, a `dart compile
/// exe` binary is not self-contained on a distroless/scratch image.
library;

export 'src/sqlite_db.dart' show SqliteDb;
