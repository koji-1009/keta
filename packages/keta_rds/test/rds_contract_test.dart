import 'dart:io';

import 'package:keta/keta.dart' show Conflict, KetaException;
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
  });

  group('error translation', () {
    test(
      'a duplicate key is a Conflict; a NOT NULL stays the driver\'s',
      () async {
        final db = _connect();
        addTearDown(db.close);
        final t = _table('conflict');
        await db.writer.execute('drop table if exists $t');
        await db.writer.execute(
          'create table $t (id text primary key, n integer not null)',
        );
        await db.writer.execute('insert into $t values (?, ?)', ['1', 1]);

        // The one condition a caller can act on, in keta's vocabulary.
        await expectLater(
          db.writer.execute('insert into $t values (?, ?)', ['1', 2]),
          throwsA(isA<Conflict>().having((e) => e.status, 'status', 409)),
        );

        // NOT NULL is the app inserting wrong data — its own bug, left raw so a
        // 409 never invites retrying the unretryable.
        await expectLater(
          db.writer.execute('insert into $t values (?, ?)', ['2', null]),
          throwsA(
            isA<ServerException>().having(
              (e) => e,
              'not keta',
              isNot(isA<KetaException>()),
            ),
          ),
        );
      },
    );

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
