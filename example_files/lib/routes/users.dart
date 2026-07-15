import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';
import 'package:keta_openapi/keta_openapi.dart';

/// `/users`. One file is one URL; the slots are what that URL answers.
final exported = Exported<Env>(
  get: Serve(
    // Query parameters drive pagination and filtering — declared in the doc
    // below, read here with the optional accessor and a code-side default.
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
  ),
  post: Serve(
    // A duplicate id needs no code here: keta_sqlite turns the engine's
    // uniqueness violation into a Conflict, and recover() renders it as a 409.
    (c) async {
      final dto = UserDto.fromJson(
        userDtoSchema.require(await c.body()) as Map<String, Object?>,
      );
      await c.get(txConn).execute(
        'insert into users (id, name, age, role, tags) values (?, ?, ?, ?, ?)',
        [dto.id, dto.name, dto.age, dto.role.name, dto.tags.join(',')],
      );
      return c.text(
        'created',
        status: 201,
        headers: {
          'location': ['/users/${dto.id}'],
        },
      );
    },
    doc: const RouteDoc(requestBody: userDtoSchema, summary: 'Create a user'),
  ),
);
