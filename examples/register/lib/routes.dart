import 'package:keta/keta.dart';
import 'package:keta_db/keta_db.dart';
import 'package:keta_multipart/keta_multipart.dart';
import 'package:keta_openapi/keta_openapi.dart';

import 'auth.dart';
import 'env.dart';
import 'events.dart';
import 'readiness.dart';
import 'user_dto.dart';

/// A custom [Capture]: the typed-DSL extension point, projecting a `Role` into a
/// path segment. `Capture<T>(parse, schema: ...)` is the whole contract — [parse]
/// throws [BadRequest] on bad input (→ 400, decided by the declaration, not by a
/// handler remembering to validate), and [schema] is the OpenAPI fragment carried
/// as data. The enum is the single source of the role vocabulary: this `enum`
/// lookup, the DTO schema's `enum` list, and this capture's `enum` schema all
/// read from the same three names, so they cannot drift.
final roleCapture = Capture<Role>(
  (s) =>
      Role.values.asNameMap()[s] ??
      (throw BadRequest('unknown role: "$s" (expected admin or member)')),
  schema: const {
    'type': 'string',
    'enum': ['admin', 'member'],
  },
);

/// Registers every route on [app]. Both routing syntaxes appear: the string
/// form with `c.param`, and the typed `on()`-builder handing the handler its
/// captured tuple.
///
/// Reads and writes are registered differently on purpose: every read below
/// sits directly on `app` and reaches the database through `c.env.db.reader`,
/// while `create`/`update`/`delete` are registered through a `/users` group
/// carrying `tx()` — see the group below for why. `c.env.bus` (Env-owned; see
/// lib/env.dart, lib/events.dart) is the write handlers' and `/users/events`'
/// shared channel, so it needs no `buildApp`-scoped parameter the way the old
/// in-process `UserEvents` did.
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

  // A readiness probe over keta_rds's RdsDb.poolStats — see lib/readiness.dart
  // for the (deliberately simple, app-owned) policy. c.env.rds is null unless
  // KETA_RDS_URL is set, because this example's real datastore stays SQLite;
  // see lib/env.dart and the README's "Readiness" section for why a second,
  // unused-for-data database handle exists here at all.
  app.get(
    '/ready',
    (c) {
      final rds = c.env.rds;
      if (rds == null) {
        return c.json({
          'status': 'ready',
          'note': 'no RDS pool configured (KETA_RDS_URL is unset)',
        });
      }
      final readiness = readinessPolicy(rds.poolStats);
      return c.json(readiness.toJson(), status: readiness.httpStatus);
    },
    doc: const RouteDoc(
      success: Success(),
      summary: 'Readiness probe (RdsDb.poolStats-backed, when configured)',
      security: [],
    ),
  );

  // A list endpoint: query parameters drive pagination (?limit=&offset=) and
  // filtering (?role) — declared for OpenAPI, read with the optional accessor +
  // a code-side default. The response is a nested DTO (UserList wraps UserDto):
  // `items` is this page, `total` is the full match count so a client can page.
  app.get(
    '/users',
    (c) async {
      // Clamp both bounds rather than trust them: an unbounded limit lets one
      // request scan the whole table, and a negative limit/offset is a SQL error
      // waiting to happen. `clamp` turns an out-of-range value into the nearest
      // legal one — a paging UI that overshoots the last page gets an empty
      // `items` with the right `total`, not a 400 and not a crash.
      final limit = (c.tryQuery<int>('limit') ?? 20).clamp(1, 100);
      final offset = (c.tryQuery<int>('offset') ?? 0).clamp(0, 1 << 31);
      final role = c.tryQuery<String>('role');
      final where = role == null ? '' : ' where role = ?';
      final rows = await c.env.db.reader.query(
        'select id, name, age, role, tags from users$where '
        'order by id limit ? offset ?',
        role == null ? [limit, offset] : [role, limit, offset],
      );
      // `total` counts the whole filtered set, independent of limit/offset — it
      // is what a client divides by page size, so it must ignore the window.
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
  );

  // A typed-DSL route driven by the custom [roleCapture]: `:role` is parsed to a
  // `Role`, so an unknown role is a 400 at the boundary and the handler receives
  // a value that is already valid. This is the same list+total shape as `/users`,
  // narrowed to one role by the path rather than the `?role` query — a second,
  // typed door onto the same data that shows a `Capture<T>` in the `on()` DSL.
  app
      .on(
        root.segments('users').segments('by-role').capture(roleCapture('role')),
      )
      .get(
        (c, (Role,) p) async {
          final rows = await c.env.db.reader.query(
            'select id, name, age, role, tags from users where role = ? order by id',
            [p.$1.name],
          );
          return c.json(
            UserList(
              items: [for (final r in rows) UserDto.fromRow(r)],
              total: rows.length,
            ).toJson(),
          );
        },
        // Not const — see the /users route above.
        doc: RouteDoc(
          success: Success(schema: userListSchema),
          summary: 'List users of a role',
        ),
      );

  // Server-Sent Events: a live feed of create/update/delete, streamed from
  // c.env.bus (see lib/events.dart's userEventsStream and lib/env.dart) — the
  // write handlers below publish onto the same bus. The doc's Success carries
  // the `text/event-stream` content type and a schema for each event's JSON
  // `data` payload — the content type names the transport, the schema names
  // what a single event decodes to (OpenAPI has no first-class event-stream
  // shape, so this is the honest projection). Security is inherited, not
  // declared: `/users/events` follows the secure-by-default [bearer], so the
  // gate runs and answers 401 *before* `c.sse` ever opens a stream — an
  // anonymous subscriber never gets a socket, only a status.
  app.get(
    '/users/events',
    (c) => c.sse(
      userEventsStream(c.env.bus),
      keepAlive: const Duration(seconds: 15),
    ),
    doc: const RouteDoc(
      success: Success(
        schema: userEventSchema,
        contentType: 'text/event-stream',
      ),
      summary: 'Live feed of user create/update/delete events',
      description:
          'An EventSource stream. Each event is named created, updated, or '
          'deleted and carries {"kind","id"}. Requires a bearer token: the '
          'security gate answers 401 before the stream opens.',
      tags: ['users', 'events'],
      operationId: 'streamUserEvents',
    ),
  );

  // The WebSocket companion to this SSE feed lives in its own small example,
  // examples/websocket, to keep the upgrade-and-gate idea on a minimal stack. It
  // is a focus choice, not a workaround: keta's response-rebuilding middleware
  // (cors, etag, gzip) rebuild through `Response.copyWith`, which carries an
  // upgrade's `Upgrade` field through untouched, so a handshake composes behind
  // this app's app-wide cors just fine.

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
        // A comma-joined empty column is `''`, and `''.split(',')` is `['']`,
        // not `[]` — the same trap UserDto.fromRow guards against. Left
        // unguarded, `GET /users/<zero-tag id>/tags/0` answered `{"tag": ""}`
        // instead of the 404 an out-of-range index gets everywhere else.
        final tagsRaw = rows.first['tags'] as String;
        final tags = tagsRaw.isEmpty ? const <String>[] : tagsRaw.split(',');
        if (p.$2 < 0 || p.$2 >= tags.length) {
          throw const NotFound('tag index out of range');
        }
        return c.json({'tag': tags[p.$2]});
      });

  // Every route that writes lives behind this ONE group, and `tx()` sits on
  // the group, not on `app` — the approved shape (see keta_db's `tx()` doc):
  // tx() pays a BEGIN/COMMIT round trip and pins a writer-pool connection for
  // its whole span, so mounting it app-wide taxes every GET (and would have
  // pinned a writer connection for `/users/events`' entire open-ended SSE
  // lifetime) for no reason — the reads above never touch it and keep using
  // `c.env.db.reader` directly. `/uploads` below writes nothing to the
  // database either, so it stays off this group too.
  final writeUsers = app.group('/users')..use(tx());

  writeUsers.on(root).post(
    (c, _) async {
      final dto = UserDto.fromJson(userDtoSchema.requireMap(await c.body()));
      await c.get(txConn).execute(
        'insert into users (id, name, age, role, tags) values (?, ?, ?, ?, ?)',
        [dto.id, dto.name, dto.age, dto.role.name, dto.tags.join(',')],
      );
      // Publish only after the write succeeds: a duplicate id throws Conflict
      // above and this line never runs, so the feed never announces a create
      // that did not happen. (A production system would emit on transaction
      // commit, not here — close enough for a demo where the tx wraps the
      // request.)
      c.env.bus.publish(usersTopic, {'kind': 'created', 'id': dto.id});
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

  // Update (PUT) and delete (DELETE) complete the CRUD surface. A write with no
  // matching row is a 404; a delete returns 204 with no body.
  writeUsers.put(
    '/:id',
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
      final changed = await c.get(txConn).execute(
        'update users set name = ?, age = ?, role = ?, tags = ? where id = ?',
        [dto.name, dto.age, dto.role.name, dto.tags.join(','), pathId],
      );
      if (changed == 0) throw const NotFound('user not found');
      c.env.bus.publish(usersTopic, {'kind': 'updated', 'id': pathId});
      return c.json(dto.toJson());
    },
    doc: const RouteDoc(
      success: Success(schema: userDtoSchema),
      requestBody: userDtoSchema,
      summary: 'Replace a user',
    ),
  );

  writeUsers.delete(
    '/:id',
    (c) async {
      final id = c.param<String>('id');
      final changed = await c.get(txConn).execute(
        'delete from users where id = ?',
        [id],
      );
      if (changed == 0) throw const NotFound('user not found');
      c.env.bus.publish(usersTopic, {'kind': 'deleted', 'id': id});
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
  // upload in memory. Persistence would be the app's job — this demo has none,
  // so it never touches the database and sits outside the tx() group above.
  app.post(
    '/uploads',
    (c) async {
      final fields = <String, String>{};
      final files = <Map<String, Object?>>[];
      await for (final part in parts(c)) {
        // A form part with no `name` is malformed for a form submission, and the
        // old `part.name ?? ''` silently collapsed every unnamed part onto the
        // one `''` key — the second overwrote the first, losing data with no
        // error. Reject it instead, naming the constraint. (Indexing unnamed
        // parts by position would be the other honest choice; rejecting is the
        // stricter one, and a demo should not invent field names.)
        final name = part.name;
        if (name == null) {
          throw const BadRequest('every multipart part must carry a name');
        }
        if (part.filename != null) {
          final bytes = await part.bytes();
          files.add({
            'field': name,
            'filename': part.filename,
            'size': bytes.length,
          });
        } else {
          fields[name] = await part.text();
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
