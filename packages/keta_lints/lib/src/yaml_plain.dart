library;

import 'package:yaml/yaml.dart';

/// Converts the `YamlMap`/`YamlList` tree from `loadYaml` into plain Dart
/// `Map<String, Object?>`/`List` so it can be diffed and walked directly.
Object? yamlToPlain(Object? node) => switch (node) {
  YamlMap() => <String, Object?>{
    for (final entry in node.nodes.entries)
      (entry.key as YamlScalar).value.toString(): yamlToPlain(entry.value),
  },
  YamlList() => [for (final item in node.nodes) yamlToPlain(item)],
  YamlScalar() => node.value,
  _ => node,
};

/// Parses [source] as YAML and returns it as a plain document map.
Map<String, Object?> loadYamlDocument(String source) {
  final plain = yamlToPlain(loadYaml(source));
  if (plain is! Map<String, Object?>) {
    throw const FormatException('expected a YAML mapping at the document root');
  }
  return plain;
}
