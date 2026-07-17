import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_multipart/keta_multipart.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'auth.dart';
import 'env.dart';
import 'user_dto.dart';

/// Registers every route on [app]. Both routing syntaxes appear: the string
/// form with `c.param`, and the typed `on()`-builder handing the handler its
/// captured tuple.
void register(App<Env> app) {
  // `security: []` is not "no opinion" — it is "public", and it overrides the
  // global default. A route that simply omits RouteDoc.security inherits the
  // default instead, which is why the distinction is worth showing.
  app.get(
    '/health',
    (c) => c.text('ok'),
    doc: const RouteDoc(
      // No schema: the probe answers `text/plain`, and a JSON schema over it
      // would be a document saying something false. Saying nothing is not.
      success: Success(),
      summary: 'Liveness probe',
      security: [],
    ),
  );

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
      success: Success(schema: userListSchema),
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
    doc: const RouteDoc(
      success: Success(schema: userDtoSchema),
      summary: 'Fetch a user',
    ),
  );

  app.on(root.segments('users')).post(
    (c, _) async {
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
    },
    doc: const RouteDoc(
      // 201, because that is what the handler above answers. The status lives in
      // the declaration rather than being guessed from its absence.
      success: Success(status: 201),
      requestBody: userDtoSchema,
      summary: 'Create a user',
    ),
  );

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
      success: Success(schema: userDtoSchema),
      requestBody: userDtoSchema,
      summary: 'Replace a user',
    ),
  );

  app.delete(
    '/users/:id',
    (c) async {
      final changed = await c.get(txConn).execute(
        'delete from users where id = ?',
        [c.param<String>('id')],
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
  );

  // The other half of authentication: the gate put the caller in the request
  // store, and the handler reads it back with the same typed Key. Nothing is
  // parsed twice, and the handler cannot see a request the gate did not admit.
  // `security: [bearer]` is declared, not inherited: c.get below asserts a
  // principal is present, and only the bearer verifier sets one. Leaving it to
  // the default would make that assumption true only by accident — add apiKey
  // to apiDefaults and the OR-combining gate would admit a caller with no
  // principal, turning this handler into a 500.
  app.get(
    '/whoami',
    (c) {
      final who = c.get(principal);
      return c.json({'id': who.id, 'admin': who.admin});
    },
    doc: const RouteDoc(
      success: Success(),
      summary: 'The authenticated caller',
      security: [bearer],
    ),
  );

  // Authorization is ordinary middleware, scoped to a group rather than the
  // whole app: `enforceSecurity` answers "who are you", `requireAdmin` answers
  // "may you". Keeping them apart is why 401 and 403 stay distinguishable.
  // The 403 is part of the contract, so it is declared. `failureResponses` is
  // how a status the gate never produces — this one comes from requireAdmin,
  // not enforceSecurity — still reaches the document.
  app
      .group('/admin')
      .use(requireAdmin())
      .get(
        '/ping',
        (c) => c.text('pong'),
        doc: const RouteDoc(
          success: Success(),
          summary: 'Admin-only liveness check',
          failureResponses: {403: errorSchema},
        ),
      );

  // A multipart upload (keta_multipart, Optional Ring 3): stream the parts once,
  // buffering small text fields and reporting file sizes without holding the
  // upload in memory. Persistence would be the app's job.
  app.post(
    '/uploads',
    (c) async {
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
    },
    doc: const RouteDoc(
      success: Success(),
      summary: 'Accept a multipart/form-data upload',
      requestBody: uploadFormSchema,
      requestBodyType: 'multipart/form-data',
    ),
  );
}
