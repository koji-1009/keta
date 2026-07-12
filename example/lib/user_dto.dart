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
