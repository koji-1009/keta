import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_openapi/keta_openapi.dart';

import '../env.dart';
import '../user_dto.dart';

/// The user routes, grouped in one file. Identical handlers to the
/// register-based example — only the way they reach the app differs.
void register(App<Env> app) {
  app.get(
    '/users/:id',
    (c) async {
      final rows = await c.env.db.reader.query(
        'select id, name, age, role, tags from users where id = ?',
        [c.param<String>('id')],
      );
      if (rows.isEmpty) throw const NotFound('user not found');
      return c.json(UserDto.fromRow(rows.first).toJson());
    },
    doc: const RouteDoc(response: userDtoSchema, summary: 'Fetch a user'),
  );

  app.on(root.segments('users')).post((c, _) async {
    final dto = UserDto.fromJson(
      userDtoSchema.require(await c.body()) as Map<String, Object?>,
    );
    await c.get(txConn).execute(
      'insert into users (id, name, age, role, tags) values (?, ?, ?, ?, ?)',
      [dto.id, dto.name, dto.age, dto.role.name, dto.tags.join(',')],
    );
    return c.text('created', status: 201);
  }, doc: const RouteDoc(requestBody: userDtoSchema, summary: 'Create a user'));

  app
      .on(
        root
            .segments('users')
            .capture(string('uid'))
            .segments('tags')
            .capture(integer('index')),
      )
      .get((c, (String, int) p) async {
        final rows = await c.env.db.reader.query(
          'select tags from users where id = ?',
          [p.$1],
        );
        if (rows.isEmpty) throw const NotFound('user not found');
        final tags = (rows.first['tags'] as String).split(',');
        if (p.$2 < 0 || p.$2 >= tags.length) {
          throw const NotFound('tag index out of range');
        }
        return c.json({'tag': tags[p.$2]});
      });
}
