import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:keta_files_example/env.dart';
import 'package:keta_files_example/user_dto.dart';
/// `/users`. One file is one URL; the slots are what that URL answers.
final exported = Exported<Env>(
  get: Serve(
    // Query parameters drive pagination (?limit=&offset=) and filtering (?role)
    // — declared in the doc below, read here with the optional accessor and a
    // code-side default. `items` is this page, `total` is the full match count.
    (c) async {
      // Clamp both bounds rather than trust them: an unbounded limit lets one
      // request scan the whole table, and a negative bound is a SQL error
      // waiting to happen. An offset past the end is an empty page with the
      // right total, not a 400 — the honest answer for a paging UI that
      // overshoots the last page.
      final limit = (c.tryQuery<int>('limit') ?? 20).clamp(1, 100);
      final offset = (c.tryQuery<int>('offset') ?? 0).clamp(0, 1 << 31);
      final role = c.tryQuery<String>('role');
      final where = role == null ? '' : ' where role = ?';
      final rows = await c.env.db.reader.query(
        'select id, name, age, role, tags from users$where '
        'order by id limit ? offset ?',
        role == null ? [limit, offset] : [role, limit, offset],
      );
      // `total` counts the whole filtered set, independent of limit/offset.
      final total = await c.env.db.reader.query(
        'select count(*) as n from users$where',
        role == null ? const [] : [role],
      );
      return c.json(
        UserList(
          items: [for (final r in rows) UserDto.fromRow(r)],
          total: total.first['n'] as int,
        ).toJson(),
      );
    },
    // Not const: userListSchema is listSchema(userDtoSchema) now, a Schema
    // built per call rather than read from a const — see lib/user_dto.dart.
    doc: RouteDoc(
      success: Success(schema: userListSchema),
      summary: 'List users',
      query: const [
        QueryParam('limit', integer),
        QueryParam('offset', integer),
        QueryParam('role', string),
      ],
    ),
  ),
  post: Serve(
    // A duplicate id needs no code here: keta_sqlite turns the engine's
    // uniqueness violation into a Conflict, and recover() renders it as a 409.
    //
    // No tx() middleware here (see lib/routes.dart's buildApp doc: keta_files
    // has no per-verb middleware, only directory-scoped, and this file also
    // serves GET) — the handler opens its own transaction directly, scoped to
    // exactly this write.
    (c) async {
      final dto = UserDto.fromJson(userDtoSchema.requireMap(await c.body()));
      await c.env.db.transaction(
        (conn) => conn.execute(
          'insert into users (id, name, age, role, tags) values (?, ?, ?, ?, ?)',
          [dto.id, dto.name, dto.age, dto.role.name, dto.tags.join(',')],
        ),
      );
      return c.text(
        'created',
        status: 201,
        headers: {
          'location': ['/users/${dto.id}'],
        },
      );
    },
    doc: const RouteDoc(
      // 201, because that is what the handler above answers. The status lives
      // in the declaration rather than being guessed from its absence.
      success: Success(status: 201),
      requestBody: userDtoSchema,
      summary: 'Create a user',
    ),
  ),
);
