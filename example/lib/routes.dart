import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_multipart/keta_multipart.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'env.dart';
import 'user_dto.dart';

/// Registers every route on [app]. Both routing syntaxes appear: the string
/// form with `c.param`, and the typed `on()`-builder handing the handler its
/// captured tuple.
void register(App<Env> app) {
  app.get('/health', (c) => c.text('ok'));

  // A list endpoint: query parameters drive pagination (?limit) and filtering
  // (?role) — declared for OpenAPI, read with the optional accessor + a
  // code-side default. The response is a nested DTO (UserList wraps UserDto).
  app.get(
    '/users',
    (c) async {
      final limit = c.tryQuery<int>('limit') ?? 20;
      final role = c.tryQuery<String>('role');
      final where = role == null ? '' : ' where role = ?';
      final rows = await c.env.db.reader.query(
        'select id, name, age, role, tags from users$where limit ?',
        role == null ? [limit] : [role, limit],
      );
      final total = await c.env.db.reader.query(
        'select count(*) as n from users$where',
        role == null ? const [] : [role],
      );
      return c.json(
        UserList(
          users: [for (final r in rows) UserDto.fromRow(r)],
          total: total.first['n'] as int,
        ).toJson(),
      );
    },
    doc: const RouteDoc(
      response: userListSchema,
      summary: 'List users',
      query: [QueryParam('limit', integer), QueryParam('role', string)],
    ),
  );

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
    // 201 Created with a Location header — response headers via the helper.
    return c.text(
      'created',
      status: 201,
      headers: {
        'location': ['/users/${dto.id}'],
      },
    );
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

  // Update (PUT) and delete (DELETE) complete the CRUD surface. A write with no
  // matching row is a 404; a delete returns 204 with no body.
  app.put(
    '/users/:id',
    (c) async {
      final dto = UserDto.fromJson(
        userDtoSchema.require(await c.body()) as Map<String, Object?>,
      );
      final changed = await c.get(txConn).execute(
        'update users set name = ?, age = ?, role = ?, tags = ? where id = ?',
        [dto.name, dto.age, dto.role.name, dto.tags.join(','), c.param<String>('id')],
      );
      if (changed == 0) throw const NotFound('user not found');
      return c.json(dto.toJson());
    },
    doc: const RouteDoc(
      requestBody: userDtoSchema,
      response: userDtoSchema,
      summary: 'Replace a user',
    ),
  );

  app.delete('/users/:id', (c) async {
    final changed = await c.get(txConn).execute(
      'delete from users where id = ?',
      [c.param<String>('id')],
    );
    if (changed == 0) throw const NotFound('user not found');
    return Response(204);
  }, doc: const RouteDoc(summary: 'Delete a user'));

  // A multipart upload (keta_multipart, Optional Ring 3): stream the parts once,
  // buffering small text fields and reporting file sizes without holding the
  // upload in memory. Persistence would be the app's job.
  app.post('/uploads', (c) async {
    final fields = <String, String>{};
    final files = <Map<String, Object?>>[];
    await for (final part in parts(c)) {
      if (part.filename != null) {
        final bytes = await part.bytes();
        files.add({
          'field': part.name,
          'filename': part.filename,
          'size': bytes.length,
        });
      } else {
        fields[part.name ?? ''] = await part.text();
      }
    }
    return c.json({'fields': fields, 'files': files});
  }, doc: const RouteDoc(
    summary: 'Accept a multipart/form-data upload',
    requestBody: uploadFormSchema,
    requestBodyType: 'multipart/form-data',
  ));
}
