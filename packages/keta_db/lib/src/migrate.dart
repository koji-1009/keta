library;

import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart' show KetaException;

import 'db.dart';

/// One migration file: `NNNN_name.sql`, identified by its numeric [version]
/// prefix and applied in ascending numeric order. The name half of the
/// filename is documentation for humans browsing the directory; it is not
/// carried here — the ledger, ordering, and drift detection key on [version]
/// and [checksum] alone.
class Migration {
  const Migration(this.version, this.sql, this.checksum);
  final String version;
  final String sql;

  /// FNV-1a 64-bit hex of the migration file's raw bytes, recorded in the
  /// ledger when the migration is applied so a later edit to an
  /// already-applied file can be detected at boot (see [_fnv1a64Hex] for why
  /// FNV and not a cryptographic hash).
  final String checksum;
}

/// The outcome of a migration run: the versions applied this run and those
/// already present.
class MigrationResult {
  const MigrationResult(this.applied, this.alreadyApplied);
  final List<String> applied;
  final List<String> alreadyApplied;
}

/// Applies pending migrations from [directory] to [db] in ascending version
/// order, recording each in the `_keta_migrations` table so it runs at most
/// once. Each migration and its bookkeeping row commit together, so a failure
/// leaves the schema exactly at the last fully-applied version. There is no
/// rollback path — fixes go forward.
///
/// The ledger row records the migration file's FNV-1a checksum alongside its
/// version so [VerifyMigrations.verifyMigrations] can later catch an edit to an
/// already-applied file. A ledger created before checksums were tracked has no
/// such column: it is detected and upgraded in place with `ALTER TABLE ... ADD
/// COLUMN` (portable across sqlite3 and PostgreSQL). Rows written before the
/// upgrade keep a NULL checksum — "applied before we tracked checksums" — and
/// verify accepts them rather than failing a database it can no longer vouch
/// for.
///
/// By default a pending version below the highest already-applied version is a
/// hard error (Flyway's default posture): a `0002` that surfaces after `0003`
/// is already applied almost always means two branches were merged in an order
/// nobody tested in sequence, and applying it silently would run it against a
/// schema its author never saw. Pass [allowOutOfOrder] `true` to accept it
/// anyway (a deliberate backfill onto an environment that legitimately ran
/// ahead).
///
/// All ledger *reads* here go through [Db.writer], not [Db.reader]: on an
/// engine with a read replica (RdsDb with a reader endpoint) the reader lags
/// the writer, and this function runs immediately after a deploy's migration
/// step writes the ledger — reading the freshly-written rows off a lagging
/// replica would see the migration as still pending and re-apply it.
///
/// **Single-applier contract (2026-07-17 adjudication)**: this function
/// assumes exactly one concurrent applier. It takes no advisory lock and
/// arbitrates nothing between callers — two processes racing this function
/// against the same database can both read the ledger as "0003 pending" and
/// both attempt to apply it. Multi-node deployments must serialize
/// application externally (a CI/CD step, an init container, a dedicated job
/// that runs once before the fleet boots) — keta ships no such arbitration.
/// The division of labour is: apply is externally serialized (this
/// function, run once); [VerifyMigrations.verifyMigrations] is what each
/// node/isolate runs at boot, and it only reads. If the single-applier
/// assumption is broken anyway, the race still fails loudly rather than
/// corrupting the schema silently — but not as a ledger primary-key
/// violation. Measured on SQLite: `BEGIN` takes the file lock, so the loser
/// serializes there and fails with `SQLITE_BUSY`/lock-timeout, or with the
/// migration body's own conflict (e.g. "table already exists") if it gets
/// that far — the ledger's per-version primary key is only the last line of
/// defense, reached only on an engine with transactional DDL that lets both
/// racers complete the migration body and reach the ledger insert.
Future<MigrationResult> applyMigrations(
  Db db, {
  String directory = 'migrations',
  bool allowOutOfOrder = false,
}) async {
  final migrations = loadMigrations(directory);

  await db.writer.execute(
    'create table if not exists _keta_migrations '
    '(version text primary key, applied_at text not null, checksum text)',
  );
  final rows = await _readLedgerForApply(db);
  // Normalize to the numeric version: the ledger stores the version string as
  // it was first applied, so an applied `0002` and a renamed-on-disk `2` are
  // the same migration and must not re-run. (loadMigrations already guarantees
  // every version parses as an int.)
  final applied = {for (final r in rows) int.parse(r['version'] as String)};
  final highestApplied = applied.isEmpty
      ? null
      : applied.reduce((a, b) => a > b ? a : b);

  final done = <String>[];
  final ran = <String>[];
  for (final m in migrations) {
    final version = int.parse(m.version);
    if (applied.contains(version)) {
      done.add(m.version);
      continue;
    }
    if (!allowOutOfOrder &&
        highestApplied != null &&
        version < highestApplied) {
      // A pending version below what is already applied: refuse rather than
      // interleave it into a history it was never tested against.
      throw StateError(
        'out-of-order migration ${m.version}: it is below the already-applied '
        'version $highestApplied. A lower version appearing after a higher one '
        'has been applied usually means two branches merged in an order never '
        'tested in sequence. Reconcile the two, or pass allowOutOfOrder: true '
        'to apply it deliberately.',
      );
    }
    try {
      await db.transaction((conn) async {
        // Delegate multi-statement parsing to the driver — a hand-rolled
        // splitter breaks on triggers and on `;`/`--` inside string literals.
        await conn.execute(m.sql);
        await conn.execute(
          'insert into _keta_migrations (version, applied_at, checksum) '
          'values (?, ?, ?)',
          [m.version, DateTime.now().toUtc().toIso8601String(), m.checksum],
        );
        return 0;
      });
    } on KetaException catch (e, st) {
      // Adapters answer in HTTP terms because that is what a request needs, and
      // a migration is not a request: a bare `Conflict(409, row already exists)`
      // names no migration and no constraint, because toString() withholds
      // detail from clients that do not exist here. Boot failures are read by a
      // person at a terminal, so say the whole thing — including the detail the
      // HTTP layer would have hidden.
      Error.throwWithStackTrace(
        StateError(
          'migration ${m.version} failed: ${e.message}'
          '${e.detail == null ? '' : ' (${e.detail})'}',
        ),
        st,
      );
    } on Object catch (e, st) {
      // The common case: a plain SQL syntax error, an unknown table, a type
      // mismatch — anything the adapter does not translate into a KetaException
      // reaches here raw, naming no migration. Wrap it so the failure says
      // which version broke, but keep the original stack so the driver frame
      // that actually threw is not lost.
      Error.throwWithStackTrace(
        StateError('migration ${m.version} failed: $e'),
        st,
      );
    }
    ran.add(m.version);
  }
  return MigrationResult(ran, done);
}

/// Reads `(version, checksum)` from the ledger for [applyMigrations], upgrading
/// a pre-checksum ledger in place. The `select` naming `checksum` is what fails
/// on a legacy ledger (the column does not exist yet); the table itself is
/// present because the caller just ran `create table if not exists`, so the
/// only reason to reach the catch is the missing column. Add it — nullable, so
/// pre-existing rows keep NULL — and re-read.
Future<List<Map<String, Object?>>> _readLedgerForApply(Db db) async {
  try {
    return await db.writer.query(
      'select version, checksum from _keta_migrations',
    );
  } on Object {
    await db.writer.execute(
      'alter table _keta_migrations add column checksum text',
    );
    return db.writer.query('select version, checksum from _keta_migrations');
  }
}

/// Reads and parses `NNNN_name.sql` files under [directory], sorted ascending
/// by numeric version. A missing directory is an error (usually a typo or wrong
/// cwd), not a silent success; duplicate numeric versions are rejected.
List<Migration> loadMigrations(String directory) {
  final dir = Directory(directory);
  if (!dir.existsSync()) {
    throw FileSystemException('migrations directory not found', directory);
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList();
  final migrations = <Migration>[];
  for (final file in files) {
    final base = file.uri.pathSegments.last;
    final stem = base.substring(0, base.length - '.sql'.length);
    final underscore = stem.indexOf('_');
    if (underscore <= 0) {
      throw FormatException('migration file must be named NNNN_name.sql', base);
    }
    final version = stem.substring(0, underscore);
    if (int.tryParse(version) == null) {
      throw FormatException('migration version must be numeric', version);
    }
    // Hash the raw file bytes, not the decoded string, so the checksum is a
    // faithful fingerprint of the file on disk (and identical between the apply
    // that records it and the verify that re-reads it).
    final bytes = file.readAsBytesSync();
    final sql = utf8.decode(bytes);
    // An empty (or whitespace-only) migration is almost always a truncated or
    // unsaved file. Recording it as "applied" would silently make it a no-op
    // that can never be re-run, so reject it up front.
    if (sql.trim().isEmpty) {
      throw FormatException('migration file is empty', base);
    }
    migrations.add(Migration(version, sql, _fnv1a64Hex(bytes)));
  }
  migrations.sort(
    (a, b) => int.parse(a.version).compareTo(int.parse(b.version)),
  );
  for (var i = 1; i < migrations.length; i++) {
    if (int.parse(migrations[i].version) ==
        int.parse(migrations[i - 1].version)) {
      throw FormatException(
        'duplicate migration version',
        migrations[i].version,
      );
    }
  }
  return migrations;
}

/// A read-only check that every migration in [directory] is recorded in the
/// `_keta_migrations` ledger — meant to be called inside `Env.boot`.
extension VerifyMigrations on Db {
  /// Throws a [StateError] naming the unapplied versions (and the command to
  /// apply them) when the schema is behind [directory], so an out-of-date
  /// database fails loudly once at boot rather than as a rain of per-request
  /// 500s. Unlike [applyMigrations] it never writes, so running it in every
  /// isolate concurrently is safe.
  ///
  /// It also compares each applied migration's file against the checksum the
  /// ledger recorded, and throws naming the version when they differ: an
  /// already-applied migration file that was edited afterward would otherwise
  /// pass verify forever while the running schema no longer matches its source.
  /// A row with a NULL checksum (applied before checksums were tracked, or on a
  /// ledger whose checksum column has not been added yet) is accepted as-is —
  /// verify cannot vouch for a fingerprint it was never given, and must not
  /// fail an otherwise-current database for it.
  ///
  /// Every ledger read goes through [Db.writer], never [Db.reader]: on an
  /// engine with a read replica the replica lags the writer, and this runs at
  /// boot right after the deploy's migration step wrote the ledger — reading a
  /// lagging replica would false-fail every node as "out of date" precisely
  /// when the schema is in fact current.
  ///
  /// A broken connection (unreachable database, corrupt file, ...) surfaces as
  /// its own error, not as this function's "unapplied migrations" StateError:
  /// those are different failures an operator must not confuse, so basic
  /// connectivity is probed before the ledger table is even consulted.
  Future<void> verifyMigrations([String directory = 'migrations']) async {
    final onDisk = loadMigrations(directory);
    // Prove the connection itself works before asking about the ledger table.
    // Only *this* query is allowed to fail as "the db is unreachable" — left
    // unguarded, it rethrows as-is, distinct from the missing-table fallback
    // below. Routed through writer for the replica-lag reason above.
    await writer.query('select 1');
    final rows = await _readLedgerForVerify();
    // Numeric version → recorded checksum (NULL for a legacy/pre-checksum row).
    final applied = <int, String?>{
      for (final row in rows)
        int.parse(row['version'] as String): row['checksum'] as String?,
    };
    final pending = <String>[];
    final drifted = <String>[];
    for (final m in onDisk) {
      final version = int.parse(m.version);
      if (!applied.containsKey(version)) {
        pending.add(m.version);
        continue;
      }
      final recorded = applied[version];
      if (recorded != null && recorded != m.checksum) {
        drifted.add(m.version);
      }
    }
    if (pending.isNotEmpty) {
      throw StateError(
        'database schema is out of date: ${pending.length} unapplied '
        "migration(s) [${pending.join(', ')}]. Apply them with the driver's "
        'migrate tool, e.g. `dart run keta_sqlite:migrate`.',
      );
    }
    if (drifted.isNotEmpty) {
      throw StateError(
        'migration checksum mismatch: [${drifted.join(', ')}] on disk '
        'differ(s) from what was applied. An already-applied migration file '
        'was edited after the fact — the running schema no longer matches its '
        'source. Restore the file, or make the change a new forward migration.',
      );
    }
  }

  /// Reads `(version, checksum)` from the ledger without writing anything.
  /// Tries the checksum-bearing shape first; a legacy ledger whose column has
  /// not been added yet (apply upgrades it, but verify must not write) falls
  /// back to reading versions only, treating every checksum as NULL; a ledger
  /// table that does not exist at all (nothing ever applied) falls back to
  /// empty, and every migration is then reported pending — the truth.
  Future<List<Map<String, Object?>>> _readLedgerForVerify() async {
    try {
      return await writer.query(
        'select version, checksum from _keta_migrations',
      );
    } on Object {
      try {
        return await writer.query('select version from _keta_migrations');
      } on Object {
        return const [];
      }
    }
  }
}

/// FNV-1a 64-bit hash of [bytes] as a 16-char hex string. Deliberately FNV and
/// not SHA-256: this detects *accidental* drift (an already-applied migration
/// file edited by mistake), not tampering by an adversary who could recompute
/// any hash anyway, and keta_db carries no crypto dependency to reach for a
/// stronger one. This is keta core's `etag()` reasoning applied to migrations;
/// the implementation is copied here rather than imported so keta_db does not
/// depend on keta's HTTP layer for a byte hash.
///
/// The hash is deliberately byte-faithful (see [loadMigrations]: "the raw file
/// bytes, not the decoded string"), so anything that rewrites bytes on
/// checkout reads to this hash as an edit — line-ending normalization included.
/// A Windows checkout under `core.autocrlf=true` rewrites a migration's LF to
/// CRLF, which is a different FNV-1a from the LF bytes CI applied and hashed,
/// so [VerifyMigrations.verifyMigrations] would report checksum drift on a
/// schema that is in fact current. Normalizing bytes before hashing would blind
/// the detector to genuine edits that happen to only touch line endings, so
/// that is not the fix; the repo instead pins `*.sql text eol=lf` in the root
/// `.gitattributes`, keeping every checkout byte-identical to what was hashed.
String _fnv1a64Hex(List<int> bytes) {
  // Dart's int is 64-bit two's complement on the native VM (keta's only target;
  // Ring 0 does not target the web), so the multiply wraps mod 2^64 exactly as
  // FNV-1a requires.
  var hash = 0xcbf29ce484222325;
  for (final b in bytes) {
    hash ^= b;
    hash *= 0x100000001b3;
  }
  // Format as two unsigned 32-bit halves so a wrapped (negative) int still
  // renders as a stable 16-hex string.
  final hi = (hash >> 32) & 0xffffffff;
  final lo = hash & 0xffffffff;
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
