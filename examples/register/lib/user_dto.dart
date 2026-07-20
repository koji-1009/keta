import 'package:keta/keta.dart';
enum Role { admin, member }

/// Rejects a tag containing a comma, at the parse boundary where client input
/// first becomes a [UserDto]. The demo stores tags as a comma-joined CSV column
/// (see [UserDto.fromRow]), so a tag with its own comma would split into two on
/// the way back out — a silent, data-corrupting round-trip. A real app would use
/// a join table and this limit would not exist; the guard is the honest cost of
/// the CSV shortcut, named at the boundary instead of hidden. Returns the tags
/// unchanged when they are all legal, so it reads inline in `fromJson`.
List<String> _checkedTags(List<String> tags) {
  for (final tag in tags) {
    if (tag.contains(',')) {
      throw BadRequest(
        'a tag may not contain a comma ("$tag"): tags are stored as a CSV '
        'column, so a comma would corrupt the round-trip — a real app would '
        'use a join table',
      );
    }
  }
  return tags;
}

class UserDto {
  const UserDto({
    required this.id,
    required this.name,
    this.age,
    required this.role,
    required this.tags,
  });

  // Kept as the canonical `=> UserDto(field: json['key'] as T, ...)` shape so
  // keta_lints' canonical checker still recognizes and round-trips it — the tag
  // validation rides in through the `tags:` argument's helper rather than a
  // hand-written block body, which would make the factory "hand-modified" and
  // silently disable the drift check (and the drift-demo test).
  factory UserDto.fromJson(Map<String, Object?> json) => UserDto(
    id: json['id'] as String,
    name: json['name'] as String,
    age: json['age'] as int?,
    role: Role.values.byName(json['role'] as String),
    tags: _checkedTags((json['tags'] as List).cast<String>()),
  );

  /// Constructs from a database row, where `tags` is a comma-joined column and
  /// `age` may be absent. Numeric-origin values are converted explicitly.
  factory UserDto.fromRow(Map<String, Object?> row) {
    final tags = row['tags'] as String? ?? '';
    return UserDto(
      id: row['id'] as String,
      name: row['name'] as String,
      age: row['age'] as int?,
      role: Role.values.byName(row['role'] as String),
      tags: tags.isEmpty ? const [] : tags.split(','),
    );
  }
  final String id;
  final String name;
  final int? age;
  final Role role;
  final List<String> tags;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (age != null) 'age': age,
    'role': role.name,
    'tags': tags,
  };
}

const userDtoSchema = Schema('UserDto', {
  'type': 'object',
  'required': ['id', 'name', 'role', 'tags'],
  'properties': {
    'id': {'type': 'string'},
    'name': {'type': 'string'},
    'age': {'type': 'integer'},
    'role': {
      'type': 'string',
      'enum': ['admin', 'member'],
    },
    'tags': {
      'type': 'array',
      'items': {'type': 'string'},
    },
  },
});

/// A paginated list response — a nested DTO: it references [UserDto] via `$ref`
/// and carries it in `deps`, so the walker collects it into components.
///
/// `items` + `total` is the generic pagination envelope: `items` is this page's
/// rows (bounded by `?limit`/`?offset`), `total` is how many match the query
/// across all pages, so a client can compute how many pages remain without
/// walking them.
///
/// `fromJson` is kept even though the server only emits this shape: a
/// Schema-backed DTO is round-trippable by this repo's canonical convention
/// (keta_lints' `keta_canonical_missing` flags a class that has a Schema and
/// `toJson` but no `fromJson`), and the drift-demo test exercises exactly that.
class UserList {
  const UserList({required this.items, required this.total});

  factory UserList.fromJson(Map<String, Object?> json) => UserList(
    items: (json['items'] as List)
        .map((e) => UserDto.fromJson(e as Map<String, Object?>))
        .toList(),
    total: json['total'] as int,
  );
  final List<UserDto> items;
  final int total;

  Map<String, Object?> toJson() => {
    'items': [for (final u in items) u.toJson()],
    'total': total,
  };
}

/// The canonical `{"items", "total"}` envelope, built by [listSchema] instead
/// of hand-written — this used to be a `const Schema` identical in shape to
/// what [listSchema] produces, minus one thing: [listSchema] closes the
/// object (`additionalProperties: false`), which the hand-written version left
/// open. Adopting the tightening rather than fighting it, since an unknown key
/// on a list envelope was never meant to be legal here, just never checked.
/// [listSchema] builds a new [Schema] per call rather than reading a `const`,
/// so — unlike the constant this replaces — `userListSchema` is a `final`, and
/// every `RouteDoc` embedding it can no longer be `const` (see lib/routes.dart).
final userListSchema = listSchema(userDtoSchema);

/// One event on the `/users/events` SSE feed — the JSON `data` payload of a
/// `created`/`updated`/`deleted` event, not a DTO with a `fromJson` (the server
/// only ever emits it). Projected under the `text/event-stream` media type: the
/// content type says the transport is an event stream, and this schema says what
/// each event's `data` line decodes to — the honest way to document an SSE
/// endpoint, since OpenAPI has no first-class event-stream shape.
const userEventSchema = Schema('UserEvent', {
  'type': 'object',
  'required': ['kind', 'id'],
  'properties': {
    'kind': {
      'type': 'string',
      'enum': ['created', 'updated', 'deleted'],
    },
    'id': {'type': 'string'},
  },
});

/// The multipart upload form — a request-body schema, not a DTO. The file field
/// is `format: binary`; the app reads it via keta_multipart, not `fromJson`.
const uploadFormSchema = Schema('UploadForm', {
  'type': 'object',
  'properties': {
    'greeting': {'type': 'string'},
    'doc': {'type': 'string', 'format': 'binary'},
  },
});
