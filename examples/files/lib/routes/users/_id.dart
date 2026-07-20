import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';

/// `/users/:id` — the `_id` in this file's name is the capture, and the only
/// place it is named. `captures` is absent because `id` is a string, which is
/// what a capture is unless the file says otherwise. It would sit beside the
/// slots rather than in one: `id` is the URL's, and all three methods below
/// read it.
final exported = Exported<Env>(
  get: Serve(
    (c) async {
      final rows = await c.env.db.reader.query(
        'select id, name, age, role, tags from users where id = ?',
        [c.param<String>('id')],
      );
      if (rows.isEmpty) throw const NotFound('user not found');
      return c.json(UserDto.fromRow(rows.first).toJson());
    },
    doc: const RouteDoc(
      success: Success(schema: userDtoSchema),
      summary: 'Fetch a user',
    ),
  ),
  // Neither write below sits under a tx() middleware — see lib/routes.dart's
  // buildApp doc: keta_files has no per-verb middleware, and this file also
  // serves GET, so each write opens its own transaction directly instead.
  put: Serve(
    // A write with no matching row is a 404, not a silent no-op.
    (c) async {
      final pathId = c.param<String>('id');
      final dto = UserDto.fromJson(userDtoSchema.requireMap(await c.body()));
      // The schema requires a body `id`, but requiring it says nothing about it
      // matching the path — unchecked, `PUT /users/1` with body id "2" updated
      // row 1 and echoed back id "2", silently renaming a row through a path
      // that named a different one.
      if (dto.id != pathId) {
        throw BadRequest(
          'body id "${dto.id}" does not match path id "$pathId"',
        );
      }
      final changed = await c.env.db.transaction(
        (conn) => conn.execute(
          'update users set name = ?, age = ?, role = ?, tags = ? where id = ?',
          [dto.name, dto.age, dto.role.name, dto.tags.join(','), pathId],
        ),
      );
      if (changed == 0) throw const NotFound('user not found');
      return c.json(dto.toJson());
    },
    doc: const RouteDoc(
      success: Success(schema: userDtoSchema),
      requestBody: userDtoSchema,
      summary: 'Replace a user',
    ),
  ),
  delete: Serve(
    (c) async {
      final changed = await c.env.db.transaction(
        (conn) => conn.execute('delete from users where id = ?', [
          c.param<String>('id'),
        ]),
      );
      if (changed == 0) throw const NotFound('user not found');
      return Response(204);
      // 204 with no body, which is what the handler answers. Declared, because a
      // fabricated 200 was right only by luck and here it was wrong.
    },
    doc: const RouteDoc(
      success: Success(status: 204),
      summary: 'Delete a user',
    ),
  ),
);
