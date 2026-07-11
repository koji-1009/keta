library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// A route file discovered under the routes directory. Each is expected to
/// declare a top-level `void register(App<...> app)`.
class RouteFile {
  /// The import path relative to the manifest, e.g. `routes/users.dart`.
  final String importPath;

  /// The import prefix and call target, e.g. `users`.
  final String prefix;

  const RouteFile(this.importPath, this.prefix);
}

const _importsMarker = 'keta_files:imports';
const _routesMarker = 'keta_files:routes';
const _endMarker = 'keta_files:end';

/// Lists `*.dart` route files directly under [routesDir], sorted by name, with
/// a unique import prefix for each. [importBase] is the path used in generated
/// imports (relative to the manifest).
List<RouteFile> discoverRouteFiles(String routesDir,
    {String importBase = 'routes'}) {
  final dir = Directory(routesDir);
  if (!dir.existsSync()) return const [];
  final names = dir
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where((n) => n.endsWith('.dart'))
      .toList()
    ..sort();

  final used = <String>{};
  return [
    for (final name in names)
      RouteFile(
        p.url.join(importBase, name),
        _uniquePrefix(_sanitize(name.substring(0, name.length - '.dart'.length)),
            used),
      ),
  ];
}

/// Rewrites the two marked regions of [source] to import and register every
/// file in [files]. Only text between `// keta_files:imports` / `:routes` and
/// the following `// keta_files:end` is touched; the rest is left verbatim.
String syncManifest(String source, List<RouteFile> files) {
  var lines = source.split('\n');
  lines = _replaceRegion(lines, _importsMarker,
      [for (final f in files) "import '${f.importPath}' as ${f.prefix};"]);
  lines = _replaceRegion(lines, _routesMarker,
      [for (final f in files) '${f.prefix}.register(app);']);
  return lines.join('\n');
}

/// The route files whose registration is absent from [source]'s regions.
List<RouteFile> unregistered(String source, List<RouteFile> files) => [
      for (final f in files)
        if (!source.contains("as ${f.prefix};") ||
            !source.contains('${f.prefix}.register('))
          f,
    ];

List<String> _replaceRegion(
    List<String> lines, String marker, List<String> content) {
  final start = lines.indexWhere((l) => l.trim() == '// $marker');
  if (start == -1) {
    throw FormatException('manifest is missing the "// $marker" marker');
  }
  final end = lines.indexWhere((l) => l.trim() == '// $_endMarker', start + 1);
  if (end == -1) {
    throw FormatException('marker "// $marker" has no "// $_endMarker"');
  }
  final indent = lines[start].substring(0, lines[start].indexOf('//'));
  return [
    ...lines.sublist(0, start + 1),
    for (final line in content) '$indent$line',
    ...lines.sublist(end),
  ];
}

String _sanitize(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return RegExp(r'^[0-9]').hasMatch(cleaned) ? '_$cleaned' : cleaned;
}

String _uniquePrefix(String base, Set<String> used) {
  var candidate = base;
  var i = 1;
  while (!used.add(candidate)) {
    candidate = '$base$i';
    i++;
  }
  return candidate;
}
