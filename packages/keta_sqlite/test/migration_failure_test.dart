/// Pins that a migration failing on a constraint names the migration and the
/// SQL collision in operator terms, not the client-facing Conflict shape.
library;

import 'dart:io';

import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

void main() {
  test('a migration that hits a constraint says which, and where', () async {
    // The adapter answers in HTTP terms, because that is what a request needs.
    // A migration is not a request: `Conflict(409, row already exists)` names
    // no migration and no constraint, and toString() withholds the detail from
    // a client that does not exist at boot. A person at a terminal reads this.
    final dir = Directory.systemTemp.createTempSync('keta_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/0001_seed.sql').writeAsStringSync(
      'create table users (email text); '
      "insert into users values ('a@x'); insert into users values ('a@x');",
    );
    // Applied second, over data that already violates it.
    File(
      '${dir.path}/0002_unique.sql',
    ).writeAsStringSync('create unique index users_email on users (email);');

    final db = SqliteDb.memory();
    addTearDown(db.close);
    await expectLater(
      applyMigrations(db, directory: dir.path),
      throwsA(
        isA<StateError>()
            .having((e) => e.message, 'names the migration', contains('0002'))
            // SQLite names the column that collided, not the index.
            .having(
              (e) => e.message,
              'names the collision',
              contains('users.email'),
            ),
      ),
    );
  });
}
