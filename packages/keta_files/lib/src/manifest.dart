library;

import 'package:dart_style/dart_style.dart';

import 'discover.dart';

const _importsMarker = 'keta_files:imports';
const _routesMarker = 'keta_files:routes';
const _endMarker = 'keta_files:end';

/// The start markers, used to detect region overlap. `:end` is shared by both
/// regions and is not a start marker.
const _startMarkers = {_importsMarker, _routesMarker};

/// The lines [file] contributes to the routes region: one binding per verb.
///
/// The URL is written into the generated call, not read from the file, so the
/// manifest reads as the route table it is — `routeSegments(const ['users',
/// ':id'], users_id.captures)` says where the file sits, in the same words the
/// tree does.
List<String> registrationsFor(RouteFile file) {
  final captures = file.declaresCaptures
      ? ', ${file.prefix}.$capturesDeclaration'
      : '';
  return [
    for (final method in file.methods) _registration(file, method, captures),
  ];
}

String _registration(RouteFile file, String method, String captures) {
  final buffer = StringBuffer()
    ..writeln('app.$method(')
    ..writeln('  routeSegments(${_templateLiteral(file.template)}$captures),')
    ..writeln('  ${file.prefix}.$method,');
  if (file.docs.contains(method)) {
    buffer.writeln('  doc: ${file.prefix}.${method}Doc,');
  }
  buffer.write(');');
  return buffer.toString();
}

String _templateLiteral(List<String> template) => template.isEmpty
    ? 'const <String>[]'
    : "const [${template.map((p) => "'$p'").join(', ')}]";

String _importFor(RouteFile file) =>
    "import '${file.importPath}' as ${file.prefix};";

/// Rewrites the two marked regions of [source] to import every route file and
/// bind every verb it serves at the URL its location denotes. Only text between
/// `// keta_files:imports` / `:routes` and the following `// keta_files:end` is
/// touched; the rest is left verbatim.
///
/// A malformed marker layout — a start marker missing its end, a start marker
/// appearing more than once (e.g. one buried in a string literal), or two
/// regions that overlap — is a [FormatException], never a silent rewrite: the
/// generator refuses to corrupt a manifest it cannot unambiguously parse.
/// The result is formatted, because the alternative is a file that can never
/// settle: the generator's line breaks are not `dart format`'s, so an unformatted
/// manifest is rewritten by the formatter, and the next sync rewrites it back.
/// Formatting here makes "synced" and "formatted" the same state, which is what
/// lets a test assert that syncing is a no-op — and that assertion is the only
/// thing standing between the tree and the routes silently disagreeing.
String syncManifest(String source, List<RouteFile> files) {
  var lines = source.split('\n');
  lines = _replaceRegion(lines, _importsMarker, [
    for (final f in files) _importFor(f),
  ]);
  lines = _replaceRegion(lines, _routesMarker, [
    for (final f in files) ...registrationsFor(f).expand((r) => r.split('\n')),
  ]);
  return DartFormatter(
    languageVersion: DartFormatter.latestLanguageVersion,
  ).format(lines.join('\n'));
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
  final routeBlock = _normalize(
    _regionContent(lines, _routesMarker).join('\n'),
  );
  return [
    for (final f in files)
      if (!imports.contains(_importFor(f)) ||
          registrationsFor(f).any((r) => !routeBlock.contains(_normalize(r))))
        f,
  ];
}

/// Code with the things `dart format` is free to move taken out: line breaks,
/// indentation, and trailing commas. None of them change what is bound, and a
/// check that noticed them would report a formatted manifest as unregistered.
String _normalize(String code) {
  var normalized = code.replaceAll(RegExp(r'\s+'), '');
  String previous;
  do {
    previous = normalized;
    // replaceAllMapped, not replaceAll: replaceAll takes the replacement
    // literally, so `$1` would be inserted as the two characters `$1`.
    normalized = normalized.replaceAllMapped(
      RegExp(r',([)\]}])'),
      (m) => m[1]!,
    );
  } while (previous != normalized);
  return normalized;
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
    for (final line in content) line.isEmpty ? line : '$indent$line',
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
