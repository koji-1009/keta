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
///
/// When the file falls under one or more `_middleware.dart` directories, their
/// scopes ride along as a third argument, outermost first —
/// `[$mw$root.scoped, $mw$admin.scoped]` — and [Exported.bind] composes them
/// around each handler. A route under no middleware directory keeps the plain
/// two-argument form, so an ordinary manifest neither churns nor grows.
String registrationFor(RouteFile file) {
  final call =
      '${file.prefix}.$exportedDeclaration'
      '.bind(app, ${_templateLiteral(file.template)}';
  if (file.middleware.isEmpty) return '$call);';
  final scopes = [
    for (final m in file.middleware) '${m.prefix}.$scopedDeclaration',
  ];
  return '$call, [${scopes.join(', ')}]);';
}

String _templateLiteral(List<String> template) => template.isEmpty
    ? 'const <String>[]'
    : "const [${template.map(_dartStringLiteral).join(', ')}]";

String _importFor(RouteFile file) =>
    _importLine(file.importPath, file.prefix);

/// A generated import line trips two analyzer infos in the consuming project,
/// both inherent to the shape this generator emits and neither fixable by
/// writing the line differently: `directives_ordering`, because the region is
/// sorted by URL/import path rather than alphabetically interleaved with the
/// file's hand-written imports, and `library_prefixes`, because every alias
/// is `$`-led on purpose (see [_aliasFor]) and so can never be
/// `lower_underscore_case`. Suppressing both here — on the line that triggers
/// them, naming exactly those two diagnostics — means the generator owns the
/// noise its own convention creates, instead of every consuming project
/// carrying a matching `ignore_for_file` the generator did not ask for and the
/// user did not choose.
const _importIgnore = '// ignore: directives_ordering, library_prefixes';

String _importLine(String importPath, String prefix) =>
    'import ${_dartStringLiteral(importPath)} as $prefix; $_importIgnore';

/// The middleware files [files] point at, deduplicated by import path and sorted,
/// so the imports region is a function of the tree alone. Only the scopes a route
/// actually falls under are imported: a `_middleware.dart` that guards nothing is
/// left out, since importing an alias nothing references is an unused-import
/// warning waiting to happen — the `orphanMiddleware` check names it instead.
List<MiddlewareFile> _referencedMiddleware(List<RouteFile> files) {
  final byPath = <String, MiddlewareFile>{};
  for (final f in files) {
    for (final m in f.middleware) {
      byPath[m.importPath] = m;
    }
  }
  return byPath.values.toList()
    ..sort((a, b) => a.importPath.compareTo(b.importPath));
}

/// Escapes [value] for embedding in a single-quoted Dart string literal — the
/// one emitter this generator's string literals go through, per the "escaping
/// centralized in one place" generator norm. A path segment is a filename, not
/// a guaranteed-safe identifier: a backslash, a single quote, or a `$` in one
/// would otherwise be written straight into the generated source and either
/// break the string literal or trigger string interpolation. POSIX also allows
/// raw control characters in a filename — a literal newline or tab would split
/// or corrupt the generated line just as surely, so every C0/C1 control is
/// escaped too (the common three by name, the rest as `\u{...}`). Runs a
/// single pass over runes rather than chained `replaceAll` calls so introduced
/// backslashes are never themselves re-escaped.
String _dartStringLiteral(String value) {
  final buffer = StringBuffer("'");
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C: // \
        buffer.write(r'\\');
      case 0x27: // '
        buffer.write(r"\'");
      case 0x24: // $
        buffer.write(r'\$');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        if (rune <= 0x1F || (rune >= 0x7F && rune <= 0x9F)) {
          buffer.write('\\u{${rune.toRadixString(16)}}');
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write("'");
  return buffer.toString();
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
///
/// [source] keeps whatever end-of-line convention it already has. A CRLF
/// manifest — Windows-checked-out or Windows-authored — would otherwise get a
/// mixed file back: the preserved lines carry their own `\r\n`, but content
/// generated here is built on plain `\n`, so a naive `split('\n')` /
/// `join('\n')` round-trip leaves a stray `\r` on every preserved line and
/// none on the generated ones. Normalizing to `\n` for the whole rewrite and
/// converting back only if the source was CRLF to begin with keeps every
/// line — preserved or generated — in one convention, which is also what
/// idempotence needs: a second sync must reproduce the same bytes, not just
/// the same characters.
String syncManifest(String source, List<RouteFile> files) {
  final crlf = source.contains('\r\n');
  final normalized = crlf ? source.replaceAll('\r\n', '\n') : source;
  // The imports region carries the route files and the middleware files they
  // fall under. Both are derived from `files` — a route file names its own
  // scopes — so `syncManifest` stays a pure function of the route list, and
  // remains idempotent: the same tree writes the same imports in the same order.
  var lines = normalized.split('\n');
  lines = _replaceRegion(lines, _importsMarker, [
    for (final f in files) _importFor(f),
    for (final m in _referencedMiddleware(files))
      _importLine(m.importPath, m.prefix),
  ]);
  lines = _replaceRegion(lines, _routesMarker, [
    for (final f in files) registrationFor(f),
  ]);
  final joined = lines.join('\n');
  return crlf ? joined.replaceAll('\n', '\r\n') : joined;
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
