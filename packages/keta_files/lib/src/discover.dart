library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// A route file: where it is, and the URL its location denotes.
///
/// What it *serves* is not here, because it is not the generator's to know: the
/// file's `exported` is a typed value, so the compiler checks its shape at the
/// one place that uses it. A generator that inspected the file to find out what
/// it serves would be re-deriving, by string matching, what the type system
/// already guarantees — and getting it wrong quietly when it missed.
class RouteFile {
  const RouteFile({
    required this.importPath,
    required this.prefix,
    required this.template,
  });

  /// The import path relative to the manifest, e.g. `routes/users/_id.dart`.
  final String importPath;

  /// The import alias, e.g. `$users_id`.
  final String prefix;

  /// The URL this file's location denotes, as parts: `['users', ':id']`. A
  /// `:`-prefixed part is a capture. Empty means `/`.
  final List<String> template;

  /// The URL, for humans and for error messages.
  String get url => template.isEmpty ? '/' : '/${template.join('/')}';
}

/// Every `*.dart` file under [routesDir], recursively, with the URL its location
/// denotes. Sorted by URL, so the manifest is a function of the tree alone and
/// not of directory listing order.
///
/// The mapping, and all of it:
///
///   routes/index.dart                  → /
///   routes/health.dart                 → /health
///   routes/users.dart                  → /users
///   routes/users/_id.dart              → /users/:id
///   routes/users/_uid/tags/_index.dart → /users/:uid/tags/:index
///
/// A leading `_` on a file or directory marks a capture; `index` denotes the
/// directory itself. Every file under the tree is a route — there is nowhere to
/// hide a helper, which is what makes the tree readable as the route table.
List<RouteFile> discoverRouteFiles(
  String routesDir, {
  String importBase = 'routes',
}) {
  final dir = Directory(routesDir);
  if (!dir.existsSync()) return const [];

  final files =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map(
            (f) => p.url.joinAll(p.split(p.relative(f.path, from: routesDir))),
          )
          .toList()
        ..sort();

  final used = <String>{};
  final byUrl = <String, String>{};
  final result = <RouteFile>[];
  for (final rel in files) {
    final template = _templateOf(rel);
    final url = template.isEmpty ? '/' : '/${template.join('/')}';
    // Two files denoting one URL is not a merge, it is a question with no
    // answer: `users.dart` and `users/index.dart` both claim /users, and
    // nothing in the tree says which wins.
    final clash = byUrl[url];
    if (clash != null) {
      throw FormatException(
        'both "$clash" and "$rel" denote $url; a URL belongs to one file',
      );
    }
    byUrl[url] = rel;
    result.add(
      RouteFile(
        importPath: p.url.join(importBase, rel),
        prefix: _uniquePrefix(_aliasFor(template), used),
        template: template,
      ),
    );
  }
  return result..sort((a, b) => a.url.compareTo(b.url));
}

/// The URL parts a relative route-file path denotes.
List<String> _templateOf(String rel) {
  final stem = rel.substring(0, rel.length - '.dart'.length);
  final parts = stem.split('/');
  if (parts.last == 'index') parts.removeLast();
  return [
    for (final part in parts)
      if (part.startsWith('_')) ':${part.substring(1)}' else part,
  ];
}

/// A readable import alias: the URL's own words, in a namespace no hand-written
/// name occupies. `/users/:id` → `$users_id`.
///
/// The `$` is not decoration. An alias derived from a URL will sooner or later
/// be a word the app already uses — `routes/metrics.dart` wants `metrics`, and
/// so does the app's own registry — and the loser of that collision would be
/// the app, told to rename a URL because of a local variable. Generated names
/// live in `$`, which nothing hand-written does, so the collision cannot happen
/// rather than being detected and worked around.
String _aliasFor(List<String> template) {
  final words = [
    for (final part in template)
      part.startsWith(':') ? part.substring(1) : part,
  ];
  return '\$${_sanitize(words.isEmpty ? 'index' : words.join('_'))}';
}

/// Turns a URL's words into the identifier part of an alias.
///
/// Reserved words need no escaping and a leading digit needs no prefix: every
/// alias is `$`-led, and `$get` is not `get` any more than `$2fa` is `2fa`.
String _sanitize(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  return cleaned.isEmpty ? 'route' : cleaned;
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
