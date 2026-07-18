/// Pins keta's tx() middleware wired to a real SqliteDb: a handler failure,
/// whichever shape it takes, rolls back only its own transaction and leaves
/// earlier commits intact.
library;

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_sqlite/keta_sqlite.dart';
import 'package:test/test.dart';

class Env implements HasLog, HasDb, Disposable {
  Env(this.log, this.db);
  @override
  final Log log;
  @override
  final Db db;

  @override
  Future<void> close() => db.close();
}

Future<Env> bootMemory() async {
  final db = SqliteDb.memory();
  await db.writer.execute(
    'create table users (id integer primary key, name text not null)',
  );
  return Env(StdoutLog(flushInterval: Duration.zero), db);
}

void main() {
  group('tx() middleware', () {
    testBothModes('rolls back the transaction when the handler fails', (
      mode,
    ) async {
      final env = await bootMemory();
      addTearDown(env.close);
      final app = App<Env>()
        ..use(recover())
        ..use(tx());
      app.post('/ok', (c) async {
        await c.get(txConn).execute('insert into users (name) values (?)', [
          'ok',
        ]);
        return c.text('done', status: 201);
      });
      app.post(
        '/fail',
        (Context<Env> c) => mode.wrap(() async {
          await c.get(txConn).execute('insert into users (name) values (?)', [
            'nope',
          ]);
          throw const BadRequest('rejected');
        })(),
      );
      final client = TestClient(app, env);

      expect((await client.post('/ok')).status, 201);
      expect((await client.post('/fail')).status, 400);

      final n = (await env.db.reader.query(
        'select count(*) n from users',
      )).single['n'];
      expect(n, 1); // only the committed /ok insert survives
    });
  });
}
