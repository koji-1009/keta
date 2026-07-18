/// The live-Postgres contract suite: types, transactions, error translation,
/// concurrency, and migrations, gated on KETA_TEST_PG (never a silent green).
library;

import 'dart:async';
import 'dart:io';

import 'package:keta/keta.dart'
    show Conflict, KetaException, UnprocessableEntity;
import 'package:keta_db/keta_db.dart';
import 'package:keta_rds/keta_rds.dart';
import 'package:postgres/postgres.dart' show ServerException;
import 'package:test/test.dart';

/// The real contract suite. It talks to an actual PostgreSQL server, so it runs
/// only when `KETA_TEST_PG` names one (a `postgres://` URL). When the variable
/// is absent the suite is reported as skipped — visibly, never as a silent
/// green — because "the tests passed" and "the tests did not run" must not look
/// the same.
final String? _pgUrl = Platform.environment['KETA_TEST_PG'];

int _seq = 0;
String _table(String stem) => '_keta_rds_test_${stem}_${_seq++}';

RdsDb _connect() => RdsDb.url(_pgUrl!);

void main() {
  if (_pgUrl == null) {
    // ignore: avoid_print
    print(
      'SKIP: keta_rds contract suite — set KETA_TEST_PG to a postgres:// URL '
      '(a reachable server) to run the type contract, transactions, conflict '
      'translation, concurrency, and migration tests against it.',
    );
    test(
      'keta_rds contract suite (needs a real Postgres)',
      () {},
      skip: 'KETA_TEST_PG is not set — no Postgres server to test against.',
    );
    return;
  }

  group('the type-mapping contract', () {
    test('each storage class maps to its contracted Dart type', () async {
      final db = _connect();
      addTearDown(db.close);
      final t = _table('types');
      await db.writer.execute('drop table if exists $t');
      await db.writer.execute(
        'create table $t ('
        'i integer, big bigint, r double precision, price numeric(10, 2), '
        'flag boolean, ts timestamptz, note text, missing text)',
      );
      await db.writer.execute(
        'insert into $t (i, big, r, price, flag, ts, note, missing) '
        'values (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          7,
          9007199254740992,
          1.5,
          '12.34',
          true,
          DateTime.utc(2026, 7, 17, 10, 30),
          'hi',
          null,
        ],
      );

      final row = (await db.reader.query(
        'select i, big, r, price, flag, ts, note, missing from $t',
      )).single;

      expect(row['i'], isA<int>());
      expect(row['i'], 7);
      expect(row['big'], isA<int>());
      expect(row['r'], isA<double>());
      expect(row['r'], 1.5);
      // NUMERIC keeps its exact decimal as a String — the whole point of this
      // adapter being the first to honour the precision clause.
      expect(row['price'], isA<String>());
      expect(row['price'], '12.34');
      expect(row['flag'], isA<bool>());
      expect(row['flag'], isTrue);
      // A timestamp comes back as an ISO 8601 String, not a DateTime.
      expect(row['ts'], isA<String>());
      expect(
        DateTime.parse(row['ts'] as String),
        DateTime.utc(2026, 7, 17, 10, 30),
      );
      expect(row['note'], 'hi');
      // NULL is present with a null value, not an absent key.
      expect(row.containsKey('missing'), isTrue);
      expect(row['missing'], isNull);
    });

    test('the three temporal types each render by their own rule', () async {
      // The live counterpart of values_test.dart: prove the driver really does
      // hand all three back as UTC-tagged DateTimes and that keta renders each
      // per §3 — a `timestamptz` as a Z-terminated instant, a bare `timestamp`
      // with NO zone designator (its zone is genuinely unknown), and a `date`
      // as a calendar day with no time-of-day.
      final db = _connect();
      addTearDown(db.close);
      final t = _table('temporal');
      await db.writer.execute('drop table if exists $t');
      await db.writer.execute(
        'create table $t (tz timestamptz, ts timestamp, d date)',
      );
      await db.writer.execute('insert into $t (tz, ts, d) values (?, ?, ?)', [
        DateTime.utc(2026, 7, 17, 10, 30),
        DateTime.utc(2026, 7, 17, 10, 30),
        DateTime.utc(2026, 7, 17),
      ]);

      final row = (await db.reader.query('select tz, ts, d from $t')).single;

      // timestamptz: a real instant, emitted as UTC with a Z.
      expect(row['tz'], isA<String>());
      expect(row['tz'], '2026-07-17T10:30:00.000Z');
      // timestamp without time zone: same wall clock, but no zone claim.
      expect(row['ts'], '2026-07-17T10:30:00.000');
      expect(row['ts'] as String, isNot(endsWith('Z')));
      // date: calendar day only, not a spurious midnight-UTC instant.
      expect(row['d'], '2026-07-17');
    });

    test('a query with no matching rows returns an empty list', () async {
      final db = _connect();
      addTearDown(db.close);
      final t = _table('empty');
      await db.writer.execute('drop table if exists $t');
      await db.writer.execute('create table $t (n integer)');
      expect(await db.reader.query('select * from $t where 1 = 0'), isEmpty);
    });
  });

  group('the DbConn contract', () {
    test('execute returns the affected row count', () async {
      final db = _connect();
      addTearDown(db.close);
      final t = _table('affected');
      await db.writer.execute('drop table if exists $t');
      await db.writer.execute('create table $t (n integer)');
      for (var i = 0; i < 3; i++) {
        await db.writer.execute('insert into $t values (?)', [i]);
      }
      expect(await db.writer.execute('update $t set n = n + 10'), 3);
      expect(await db.writer.execute('delete from $t where n = 999'), 0);
      expect(await db.writer.execute('delete from $t'), 3);
    });
  });

  group('transactions', () {
    test('commit on a clean return, roll back on a throw', () async {
      final db = _connect();
      addTearDown(db.close);
      final t = _table('tx');
      await db.writer.execute('drop table if exists $t');
      await db.writer.execute('create table $t (name text)');

      await db.transaction((c) async {
        await c.execute('insert into $t values (?)', ['ada']);
        return 0;
      });
      expect(
        (await db.reader.query('select count(*) n from $t')).single['n'],
        1,
      );

      await expectLater(
        db.transaction((c) async {
          await c.execute('insert into $t values (?)', ['grace']);
          throw StateError('boom');
        }),
        throwsStateError,
      );
      // The rolled-back insert left nothing behind.
      expect(
        (await db.reader.query('select count(*) n from $t')).single['n'],
        1,
      );
    });

    test('a nested transaction is a StateError', () async {
      final db = _connect();
      addTearDown(db.close);
      await expectLater(
        db.transaction((_) => db.transaction((_) async => 0)),
        throwsStateError,
      );
    });

    test('a zone captured inside a finished transaction does not '
        'false-positive as nested', () async {
      // Regression: the nesting guard used to stamp a constant `true` into
      // the zone, so a Zone reference captured inside one transaction and
      // reused after it completed would still read as "inside a
      // transaction" forever, false-positiving on a perfectly legitimate,
      // unrelated later call.
      final db = _connect();
      addTearDown(db.close);

      late Zone stale;
      await db.transaction((_) async {
        stale = Zone.current;
        return 0;
      });

      final result = await stale.run(() => db.transaction((_) async => 1));
      expect(result, 1);
    });
  });

  group('error translation', () {
    test(
      'the integrity violations each land on their contracted keta exception',
      () async {
        final db = _connect();
        addTearDown(db.close);
        final t = _table('conflict');
        await db.writer.execute('drop table if exists $t');
        await db.writer.execute(
          'create table $t '
          '(id text primary key, n integer not null, age integer check (age >= 0))',
        );
        await db.writer.execute('insert into $t values (?, ?, ?)', [
          '1',
          1,
          30,
        ]);

        // A duplicate primary key: a Conflict (409).
        await expectLater(
          db.writer.execute('insert into $t values (?, ?, ?)', ['1', 2, 30]),
          throwsA(isA<Conflict>().having((e) => e.status, 'status', 409)),
        );

        // NOT NULL: a well-formed request the schema rejects → 422, not a raw
        // 500 (this reverses the pre-E-17 "left raw" behaviour deliberately).
        await expectLater(
          db.writer.execute('insert into $t values (?, ?, ?)', ['2', null, 30]),
          throwsA(
            isA<UnprocessableEntity>().having((e) => e.status, 'status', 422),
          ),
        );

        // CHECK: also 422.
        await expectLater(
          db.writer.execute('insert into $t values (?, ?, ?)', ['3', 1, -5]),
          throwsA(
            isA<UnprocessableEntity>().having((e) => e.status, 'status', 422),
          ),
        );
      },
    );

    test('a foreign-key violation is a Conflict', () async {
      final db = _connect();
      addTearDown(db.close);
      final parent = _table('fk_parent');
      final child = _table('fk_child');
      await db.writer.execute('drop table if exists $child');
      await db.writer.execute('drop table if exists $parent');
      await db.writer.execute('create table $parent (id integer primary key)');
      await db.writer.execute(
        'create table $child '
        '(id integer primary key, parent_id integer references $parent(id))',
      );
      addTearDown(() async {
        await db.writer.execute('drop table if exists $child');
        await db.writer.execute('drop table if exists $parent');
      });

      // Inserting a child whose parent does not exist violates the FK.
      await expectLater(
        db.writer.execute('insert into $child values (?, ?)', [1, 999]),
        throwsA(isA<Conflict>().having((e) => e.status, 'status', 409)),
      );
    });

    test(
      'inside a transaction a duplicate is still a Conflict, and rolls back',
      () async {
        final db = _connect();
        addTearDown(db.close);
        final t = _table('conflict_tx');
        await db.writer.execute('drop table if exists $t');
        await db.writer.execute('create table $t (id text primary key)');
        await db.writer.execute('insert into $t values (?)', ['1']);

        await expectLater(
          db.transaction((c) => c.execute('insert into $t values (?)', ['1'])),
          throwsA(isA<Conflict>()),
        );
        expect(await db.reader.query('select * from $t'), hasLength(1));
      },
    );
  });

  test(
    'concurrent transactions serialize — no nesting error, no lost updates',
    () async {
      final db = _connect();
      addTearDown(db.close);
      final t = _table('counter');
      await db.writer.execute('drop table if exists $t');
      await db.writer.execute(
        'create table $t (id integer primary key, n integer)',
      );
      await db.writer.execute('insert into $t values (1, 0)');

      // 100 concurrent read-modify-write increments, each in its own
      // transaction pinning a pooled connection. `for update` locks the row so
      // the read-then-write pairs cannot interleave and lose updates; the pool
      // (bounded well below 100) must hand connections round without deadlock.
      await Future.wait([
        for (var i = 0; i < 100; i++)
          db.transaction((c) async {
            final rows = await c.query(
              'select n from $t where id = 1 for update',
            );
            final n = rows.single['n'] as int;
            await c.execute('update $t set n = ? where id = 1', [n + 1]);
            return 0;
          }),
      ]);

      final n = (await db.reader.query(
        'select n from $t where id = 1',
      )).single['n'];
      expect(n, 100);
    },
  );

  group('migrations end-to-end', () {
    test('apply in order, record, stay idempotent, and verify', () async {
      final dir = Directory.systemTemp.createTempSync('keta_rds_mig');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 0001 carries two statements in one file — exercises the simple-protocol
      // multi-statement path.
      File('${dir.path}/0001_create_users.sql').writeAsStringSync(
        'create table if not exists _keta_rds_users '
        '(id integer primary key, name text); '
        "insert into _keta_rds_users values (1, 'ada');",
      );
      File(
        '${dir.path}/0002_add_email.sql',
      ).writeAsStringSync('alter table _keta_rds_users add column email text;');

      final db = _connect();
      addTearDown(() async {
        await db.writer.execute('drop table if exists _keta_rds_users');
        await db.writer.execute('drop table if exists _keta_migrations');
        await db.close();
      });
      await db.writer.execute('drop table if exists _keta_rds_users');
      await db.writer.execute('drop table if exists _keta_migrations');

      final first = await applyMigrations(db, directory: dir.path);
      expect(first.applied, ['0001', '0002']);

      // The email column exists only if 0002 ran after 0001.
      await db.writer.execute(
        'insert into _keta_rds_users (id, name, email) values (?, ?, ?)',
        [2, 'grace', 'g@x'],
      );
      expect(
        (await db.reader.query(
          'select email from _keta_rds_users where id = 2',
        )).single['email'],
        'g@x',
      );

      final second = await applyMigrations(db, directory: dir.path);
      expect(second.applied, isEmpty);
      expect(second.alreadyApplied, ['0001', '0002']);

      await expectLater(db.verifyMigrations(dir.path), completes);
    });

    test(
      'upgrades a real pre-checksum ledger with ALTER TABLE (postgres syntax)',
      () async {
        final dir = Directory.systemTemp.createTempSync('keta_rds_alter');
        addTearDown(() => dir.deleteSync(recursive: true));
        final t = _table('alter_users');
        File(
          '${dir.path}/0001_one.sql',
        ).writeAsStringSync('create table $t (id integer);');

        final db = _connect();
        addTearDown(() async {
          await db.writer.execute('drop table if exists $t');
          await db.writer.execute('drop table if exists _keta_migrations');
          await db.close();
        });
        await db.writer.execute('drop table if exists $t');
        await db.writer.execute('drop table if exists _keta_migrations');

        // A ledger in the old (no-checksum) shape with 0001 already applied,
        // exactly what an older keta_db would have left behind.
        await db.writer.execute(
          'create table _keta_migrations '
          '(version text primary key, applied_at text not null)',
        );
        await db.writer.execute(
          'insert into _keta_migrations (version, applied_at) values '
          "('0001', '2020-01-01T00:00:00Z')",
        );
        await db.writer.execute('create table $t (id integer)');

        File(
          '${dir.path}/0002_two.sql',
        ).writeAsStringSync('alter table $t add column email text;');

        // The real ALTER TABLE ... ADD COLUMN runs against PostgreSQL here.
        final result = await applyMigrations(db, directory: dir.path);
        expect(result.applied, ['0002']);
        expect(result.alreadyApplied, ['0001']);
        final rows = await db.reader.query(
          'select version, checksum from _keta_migrations order by version',
        );
        expect(rows[0]['checksum'], isNull); // legacy 0001
        expect(rows[1]['checksum'], isNotNull); // freshly-hashed 0002

        await expectLater(db.verifyMigrations(dir.path), completes);
      },
    );
  });

  group('statement timeout', () {
    test('a statement that outruns the cap is cancelled as a raw 500 (57014), '
        'not a keta exception', () async {
      // A 50ms cap on every pooled connection; a 2s sleep must trip it.
      final db = RdsDb.url(
        _pgUrl!,
        statementTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(db.close);

      // PostgreSQL cancels the statement server-side with SQLSTATE 57014.
      // keta_rds deliberately does NOT translate 57014 (outside E-17's remit),
      // so it stays the driver's own ServerException and earns a plain 500 —
      // emphatically not a TransientFailure or Unavailable, which would invite
      // a blind retry of a statement that blew its own deadline.
      await expectLater(
        db.reader.query('select pg_sleep(2)'),
        throwsA(
          isA<ServerException>()
              .having((e) => e.code, 'code', '57014')
              .having((e) => e, 'not keta', isNot(isA<KetaException>())),
        ),
      );
    });

    test('a statement within the cap runs normally', () async {
      final db = RdsDb.url(
        _pgUrl!,
        statementTimeout: const Duration(seconds: 30),
      );
      addTearDown(db.close);
      final row = (await db.reader.query('select 1 as n')).single;
      expect(row['n'], 1);
    });
  });

  group('lifecycle', () {
    test(
      'close is idempotent and post-close operations throw StateError',
      () async {
        final db = _connect();
        final t = _table('lifecycle');
        await db.writer.execute('drop table if exists $t');
        await db.writer.execute('create table $t (k text)');
        await db.close();
        await db.close(); // idempotent
        await expectLater(db.reader.query('select 1'), throwsStateError);
        await expectLater(
          db.writer.execute('insert into $t values (?)', ['x']),
          throwsStateError,
        );
      },
    );
  });
}
