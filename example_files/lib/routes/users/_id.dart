import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/users/:id` — the `_id` in this file's name is the capture, and the only
/// place it is named. `captures` is absent because `id` is a string, which is
/// what a capture is unless the file says otherwise.
final exported = Exported<Env>([
  const Get(_fetch, doc: _fetchDoc),
  const Put(_replace, doc: _replaceDoc),
  const Delete(_remove, doc: _removeDoc),
]);

const _fetchDoc = RouteDoc(response: userDtoSchema, summary: 'Fetch a user');

Future<Response> _fetch(Context<Env> c) async {
  final rows = await c.env.db.reader.query(
    'select id, name, age, role, tags from users where id = ?',
    [c.param<String>('id')],
  );
  if (rows.isEmpty) throw const NotFound('user not found');
  return c.json(UserDto.fromRow(rows.first).toJson());
}

const _replaceDoc = RouteDoc(
  requestBody: userDtoSchema,
  response: userDtoSchema,
  summary: 'Replace a user',
);

Future<Response> _replace(Context<Env> c) async {
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
}

const _removeDoc = RouteDoc(summary: 'Delete a user');

Future<Response> _remove(Context<Env> c) async {
  final changed = await c.get(txConn).execute(
    'delete from users where id = ?',
    [c.param<String>('id')],
  );
  if (changed == 0) throw const NotFound('user not found');
  return Response(204);
}
