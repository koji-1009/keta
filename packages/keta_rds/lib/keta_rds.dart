/// keta_rds — a [Db] adapter binding keta_db to PostgreSQL over
/// package:postgres. Owns a bounded reader/writer connection pool, error
/// translation (uniqueness / foreign-key → Conflict; NOT NULL / CHECK →
/// UnprocessableEntity; serialization failure / deadlock → TransientFailure;
/// unreachable / pool-exhausted → Unavailable), and the §3 type-mapping
/// contract; it writes no wire protocol of its own.
///
/// [Endpoint], [SslMode], and [ConnectionSettings] are re-exported from
/// package:postgres for the typed [RdsDb] constructor — connection endpoints
/// are the app's own configuration, distinct from the query-time driver
/// vocabulary the adapter deliberately keeps out of handlers.
library;

export 'package:postgres/postgres.dart'
    show ConnectionSettings, Endpoint, SslMode;

export 'src/migrate_url.dart' show requirePostgresUrl;
export 'src/rds_db.dart' show RdsDb;
