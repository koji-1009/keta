import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/users/:id` — the `_id` in this file's name is the capture, and the only
/// place it is named. `captures` is absent because `id` is a string, which is
/// what a capture is unless the file says otherwise. It would sit beside the
/// slots rather than in one: `id` is the URL's, and all three methods below
/// read it.
final exported = Exported<Env>(
  get: Serve((c) async {
    final rows = await c.env.db.reader.query(
      'select id, name, age, role, tags from users where id = ?',
      [c.param<String>('id')],
    );
    if (rows.isEmpty) throw const NotFound('user not found');
    return c.json(UserDto.fromRow(rows.first).toJson());
  }, doc: const RouteDoc(response: userDtoSchema, summary: 'Fetch a user')),
  put: Serve(
    // A write with no matching row is a 404, not a silent no-op.
    (c) async {
      final dto = UserDto.fromJson(
        userDtoSchema.require(await c.body()) as Map<String, Object?>,
      );
      final changed = await c.get(txConn).execute(
        'update users set name = ?, age = ?, role = ?, tags = ? where id = ?',
        [
          dto.name,
          dto.age,
          dto.role.name,
          dto.tags.join(','),
          c.param<String>('id'),
        ],
      );
      if (changed == 0) throw const NotFound('user not found');
      return c.json(dto.toJson());
    },
    doc: const RouteDoc(
      requestBody: userDtoSchema,
      response: userDtoSchema,
      summary: 'Replace a user',
    ),
  ),
  delete: Serve((c) async {
    final changed = await c.get(txConn).execute(
      'delete from users where id = ?',
      [c.param<String>('id')],
    );
    if (changed == 0) throw const NotFound('user not found');
    return Response(204);
  }, doc: const RouteDoc(summary: 'Delete a user')),
);
