import 'package:keta_openapi/keta_openapi.dart';

enum Role { admin, member }

class UserDto {
  const UserDto({
    required this.id,
    required this.name,
    this.age,
    required this.role,
    required this.tags,
  });

  factory UserDto.fromJson(Map<String, Object?> json) => UserDto(
    id: json['id'] as String,
    name: json['name'] as String,
    age: json['age'] as int?,
    role: Role.values.byName(json['role'] as String),
    tags: (json['tags'] as List).cast<String>(),
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
class UserList {
  const UserList({required this.users, required this.total});

  factory UserList.fromJson(Map<String, Object?> json) => UserList(
    users: (json['users'] as List)
        .map((e) => UserDto.fromJson(e as Map<String, Object?>))
        .toList(),
    total: json['total'] as int,
  );
  final List<UserDto> users;
  final int total;

  Map<String, Object?> toJson() => {
    'users': [for (final u in users) u.toJson()],
    'total': total,
  };
}

const userListSchema = Schema(
  'UserList',
  {
    'type': 'object',
    'required': ['users', 'total'],
    'properties': {
      'users': {
        'type': 'array',
        'items': {r'$ref': '#/components/schemas/UserDto'},
      },
      'total': {'type': 'integer'},
    },
  },
  deps: [userDtoSchema],
);

/// The multipart upload form — a request-body schema, not a DTO. The file field
/// is `format: binary`; the app reads it via keta_multipart, not `fromJson`.
const uploadFormSchema = Schema('UploadForm', {
  'type': 'object',
  'properties': {
    'greeting': {'type': 'string'},
    'doc': {'type': 'string', 'format': 'binary'},
  },
});
