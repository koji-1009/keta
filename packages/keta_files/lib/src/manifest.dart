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

/// The start markers, used to detect region overlap. `:end` is shared by both
/// regions and is not a start marker.
const _startMarkers = {_importsMarker, _routesMarker};

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
///
/// A malformed marker layout — a start marker missing its end, a start marker
/// appearing more than once (e.g. one buried in a string literal), or two
/// regions that overlap — is a [FormatException], never a silent rewrite: the
/// generator refuses to corrupt a manifest it cannot unambiguously parse. The
/// markers must therefore not appear inside string literals or other non-comment
/// context.
String syncManifest(String source, List<RouteFile> files) {
  var lines = source.split('\n');
  lines = _replaceRegion(lines, _importsMarker,
      [for (final f in files) "import '${f.importPath}' as ${f.prefix};"]);
  lines = _replaceRegion(lines, _routesMarker,
      [for (final f in files) '${f.prefix}.register(app);']);
  return lines.join('\n');
}

/// The route files whose registration is absent from [source]'s managed
/// regions. Matching is exact and region-scoped — the generated `import ... as
/// prefix;` and `prefix.register(app);` lines must appear inside the
/// `imports`/`routes` regions — so a mention in a comment, a string literal, or
/// a coincidental substring of another prefix never counts as registered.
List<RouteFile> unregistered(String source, List<RouteFile> files) {
  final lines = source.split('\n');
  final imports = {
    for (final l in _regionContent(lines, _importsMarker)) l.trim(),
  };
  final registers = {
    for (final l in _regionContent(lines, _routesMarker)) l.trim(),
  };
  return [
    for (final f in files)
      if (!imports.contains("import '${f.importPath}' as ${f.prefix};") ||
          !registers.contains('${f.prefix}.register(app);'))
        f,
  ];
}

List<String> _replaceRegion(
    List<String> lines, String marker, List<String> content) {
  final start = _uniqueMarker(lines, marker);
  final end = lines.indexWhere((l) => l.trim() == '// $_endMarker', start + 1);
  if (end == -1) {
    throw FormatException('marker "// $marker" has no "// $_endMarker"');
  }
  // The region between a start marker and its end must contain no other marker;
  // otherwise a later region's replacement would swallow it (and the code
  // between). Reject rather than silently delete.
  for (var i = start + 1; i < end; i++) {
    final trimmed = lines[i].trim();
    for (final other in _startMarkers) {
      if (trimmed == '// $other') {
        throw FormatException(
            'marker "// $marker" region overlaps "// $other"');
      }
    }
  }
  final indent = lines[start].substring(0, lines[start].indexOf('//'));
  return [
    ...lines.sublist(0, start + 1),
    for (final line in content) '$indent$line',
    ...lines.sublist(end),
  ];
}

/// The index of the sole line that is exactly `// $marker`. Absent or duplicated
/// (e.g. a copy inside a string literal) is a [FormatException].
int _uniqueMarker(List<String> lines, String marker) {
  final matches = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].trim() == '// $marker') i,
  ];
  if (matches.isEmpty) {
    throw FormatException('manifest is missing the "// $marker" marker');
  }
  if (matches.length > 1) {
    throw FormatException('marker "// $marker" appears more than once');
  }
  return matches.single;
}

/// The content lines of [marker]'s region, or an empty list when the region is
/// absent. Never throws — used by the read-only [unregistered] check.
List<String> _regionContent(List<String> lines, String marker) {
  final start = lines.indexWhere((l) => l.trim() == '// $marker');
  if (start == -1) return const [];
  final end = lines.indexWhere((l) => l.trim() == '// $_endMarker', start + 1);
  if (end == -1) return const [];
  return lines.sublist(start + 1, end);
}

/// Dart reserved words and built-in identifiers that cannot be used as an import
/// prefix. A sanitized name colliding with one is suffixed with `_`.
const _reservedWords = {
  'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
  'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
  'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
  'factory', 'false', 'final', 'finally', 'for', 'function', 'get', 'hide',
  'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
  'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
  'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
  'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'while', 'with',
  'yield',
};

/// Turns a file stem into a valid, non-reserved Dart identifier: non-identifier
/// characters become `_`, a leading digit or an empty result is prefixed with
/// `_`, and a reserved word is suffixed with `_`.
String _sanitize(String name) {
  var cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (cleaned.isEmpty) return 'route'; // pathological: a file literally ".dart"
  if (RegExp(r'^[0-9]').hasMatch(cleaned)) cleaned = '_$cleaned';
  if (_reservedWords.contains(cleaned)) cleaned = '${cleaned}_';
  return cleaned;
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
