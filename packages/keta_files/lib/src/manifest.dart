library;

import 'discover.dart';
import 'export.dart';

const _importsMarker = 'keta_files:imports';
const _routesMarker = 'keta_files:routes';
const _endMarker = 'keta_files:end';

/// The start markers, used to detect region overlap. `:end` is shared by both
/// regions and is not a start marker.
const _startMarkers = {_importsMarker, _routesMarker};

/// Wraps every generated region. `dart format` leaves what is between these
/// alone, which is what lets a synced manifest and a formatted one be the same
/// state: without it a binding wider than 80 columns is reflowed by the
/// formatter, the next sync writes it back, and the file oscillates forever —
/// taking "syncing is a no-op" with it, which is the only assertion standing
/// between the tree and the routes disagreeing.
///
/// Saying so in the file also beats the alternative of the generator carrying a
/// formatter to agree with: this region is machine-owned, and now says so to the
/// formatter and the reader in the same breath.
const _formatOff = '// dart format off';
const _formatOn = '// dart format on';

/// The line [file] contributes to the routes region.
///
/// One line per URL, and the URL is in it: the manifest reads as the route table
/// it is, in the same words the tree uses. What the file serves is not spelled
/// out here — that is its `exported`'s type to state and the compiler's to
/// check, not this generator's to guess.
String registrationFor(RouteFile file) =>
    '${file.prefix}.$exportedDeclaration'
    '.bind(app, ${_templateLiteral(file.template)});';

String _templateLiteral(List<String> template) => template.isEmpty
    ? 'const <String>[]'
    : "const [${template.map(_dartStringLiteral).join(', ')}]";

String _importFor(RouteFile file) =>
    'import ${_dartStringLiteral(file.importPath)} as ${file.prefix};';

/// Escapes [value] for embedding in a single-quoted Dart string literal — the
/// one emitter this generator's string literals go through, per the "escaping
/// centralized in one place" generator norm. A path segment is a filename, not
/// a guaranteed-safe identifier: a backslash, a single quote, or a `$` in one
/// would otherwise be written straight into the generated source and either
/// break the string literal or trigger string interpolation. The backslash is
/// escaped first so it cannot double-escape the quote/dollar this function
/// introduces.
String _dartStringLiteral(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');
  return "'$escaped'";
}

/// Rewrites the two marked regions of [source] to import every route file and
/// bind every verb it serves at the URL its location denotes. Only text between
/// `// keta_files:imports` / `:routes` and the following `// keta_files:end` is
/// touched; the rest is left verbatim.
///
/// A malformed marker layout — a start marker missing its end, a start marker
/// appearing more than once (e.g. one buried in a string literal), or two
/// regions that overlap — is a [FormatException], never a silent rewrite: the
/// generator refuses to corrupt a manifest it cannot unambiguously parse.
///
/// Each region is fenced with `// dart format off`/`on`, so what is written
/// here is what stays: see [_formatOff].
String syncManifest(String source, List<RouteFile> files) {
  var lines = source.split('\n');
  lines = _replaceRegion(lines, _importsMarker, [
    for (final f in files) _importFor(f),
  ]);
  lines = _replaceRegion(lines, _routesMarker, [
    for (final f in files) registrationFor(f),
  ]);
  return lines.join('\n');
}

/// The route files whose bindings are absent from [source]'s managed regions —
/// a file under routes/ that the app does not serve. Forgetting is otherwise
/// silent: the file compiles, the tests pass, and the URL 404s.
///
/// Matching is exact and region-scoped, so a mention in a comment, a string
/// literal, or a coincidental substring never counts as registered.
List<RouteFile> unregistered(String source, List<RouteFile> files) {
  final lines = source.split('\n');
  final imports = {
    for (final l in _regionContent(lines, _importsMarker)) l.trim(),
  };
  // An exact line match: the region is fenced from the formatter, so a binding
  // is the one line the generator wrote and stays that way.
  final routes = {
    for (final l in _regionContent(lines, _routesMarker)) l.trim(),
  };
  return [
    for (final f in files)
      if (!imports.contains(_importFor(f)) ||
          !routes.contains(registrationFor(f)))
        f,
  ];
}

List<String> _replaceRegion(
  List<String> lines,
  String marker,
  List<String> content,
) {
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
          'marker "// $marker" region overlaps "// $other"',
        );
      }
    }
  }
  final indent = lines[start].substring(0, lines[start].indexOf('//'));
  return [
    ...lines.sublist(0, start + 1),
    '$indent$_formatOff',
    for (final line in content) line.isEmpty ? line : '$indent$line',
    '$indent$_formatOn',
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
