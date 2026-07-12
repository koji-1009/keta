import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'env.dart';
import 'user_dto.dart';

/// Registers every route on [app]. Both routing syntaxes appear: the string
/// form with `c.param`, and the typed `on()`-builder handing the handler its
/// captured tuple.
void register(App<Env> app) {
  app.get('/health', (c) => c.text('ok'));

  app.get(
    '/users/:id',
    (c) async {
      final rows = await c.env.db.reader.query(
        'select id, name, age, role, tags from users where id = ?',
        [c.param<String>('id')],
      );
      if (rows.isEmpty) throw const KetaException(404, 'user not found');
      return c.json(UserDto.fromRow(rows.first).toJson());
    },
    doc: const RouteDoc(response: userDtoSchema, summary: 'Fetch a user'),
  );

  app.on(root.lit('users')).post((c, _) async {
    final dto = UserDto.fromJson(
      userDtoSchema.require(await c.body()) as Map<String, Object?>,
    );
    await c.get(txConn).execute(
      'insert into users (id, name, age, role, tags) values (?, ?, ?, ?, ?)',
      [dto.id, dto.name, dto.age, dto.role.name, dto.tags.join(',')],
    );
    return c.text('created', 201);
  }, doc: const RouteDoc(requestBody: userDtoSchema, summary: 'Create a user'));

  app
      .on(
        root
            .lit('users')
            .cap(named(str, 'uid'))
            .lit('tags')
            .cap(named(integer, 'index')),
      )
      .get((c, (String, int) p) async {
        final rows = await c.env.db.reader.query(
          'select tags from users where id = ?',
          [p.$1],
        );
        if (rows.isEmpty) throw const KetaException(404, 'user not found');
        final tags = (rows.first['tags'] as String).split(',');
        if (p.$2 < 0 || p.$2 >= tags.length) {
          throw const KetaException(404, 'tag index out of range');
        }
        return c.json({'tag': tags[p.$2]});
      });
}
