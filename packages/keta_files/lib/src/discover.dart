library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

/// The HTTP verbs a route file may serve, as the names it exports them under.
/// Lower-case because they are Dart functions, and named for the method because
/// that is the convention every file-routing framework converged on.
const httpMethods = [
  'get',
  'post',
  'put',
  'delete',
  'patch',
  'head',
  'options',
];

/// The name a route file gives the map of its captures' types.
const capturesDeclaration = 'captures';

/// A route file: where it is, what URL its location denotes, and what it serves.
class RouteFile {
  const RouteFile({
    required this.importPath,
    required this.prefix,
    required this.template,
    required this.methods,
    required this.docs,
    required this.declaresCaptures,
  });

  /// The import path relative to the manifest, e.g. `routes/users/_id.dart`.
  final String importPath;

  /// The import alias, e.g. `\$users_id`.
  final String prefix;

  /// The URL this file's location denotes, as parts: `['users', ':id']`. A
  /// `:`-prefixed part is a capture. Empty means `/`.
  final List<String> template;

  /// The verbs it exports, in [httpMethods] order.
  final List<String> methods;

  /// The verbs that also export a `<method>Doc`.
  final Set<String> docs;

  /// Whether it declares [capturesDeclaration].
  final bool declaresCaptures;

  /// The URL, for humans and for error messages.
  String get url => template.isEmpty ? '/' : '/${template.join('/')}';
}

/// Every `*.dart` file under [routesDir], recursively, with the URL its location
/// denotes and the verbs it exports. Sorted by URL so the manifest is a function
/// of the tree alone, not of directory listing order.
///
/// The mapping, and all of it:
///
///   routes/index.dart                 → /
///   routes/health.dart                → /health
///   routes/users.dart                 → /users
///   routes/users/_id.dart             → /users/:id
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

    final source = File(p.join(routesDir, rel)).readAsStringSync();
    final exports = _topLevelNames(source, rel);
    final methods = [
      for (final m in httpMethods)
        if (exports.contains(m)) m,
    ];
    if (methods.isEmpty) {
      throw FormatException(
        '"$rel" exports no HTTP method, so it serves nothing at $url. '
        'Export one of ${httpMethods.join(', ')}, or delete the file.',
      );
    }
    result.add(
      RouteFile(
        importPath: p.url.join(importBase, rel),
        prefix: _uniquePrefix(_aliasFor(template), used),
        template: template,
        methods: methods,
        docs: {
          for (final m in methods)
            if (exports.contains('${m}Doc')) m,
        },
        declaresCaptures: exports.contains(capturesDeclaration),
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
/// name occupies. `/users/:id` → `\$users_id`.
///
/// The `\$` is not decoration. An alias derived from a URL will sooner or later
/// be a word the app already uses — `routes/metrics.dart` wants `metrics`, and
/// so does the app's own registry — and the loser of that collision would be
/// the app, told to rename a URL because of a local variable. Generated names
/// live in `\$`, which nothing hand-written does, so the collision cannot happen
/// rather than being detected and worked around.
String _aliasFor(List<String> template) {
  final words = [
    for (final part in template)
      part.startsWith(':') ? part.substring(1) : part,
  ];
  return '\$${_sanitize(words.isEmpty ? 'index' : words.join('_'))}';
}

/// The top-level function and variable names [source] declares.
///
/// Parsed, not resolved: which names a file declares is a syntactic question,
/// and answering it syntactically means the manifest can be synced without a
/// working analysis context — which matters, because the manifest is exactly
/// what is missing when the context would fail to build.
Set<String> _topLevelNames(String source, String rel) {
  final result = parseString(content: source, throwIfDiagnostics: false);
  if (result.errors.any((e) => e.severity.name == 'ERROR')) {
    throw FormatException('"$rel" does not parse: ${result.errors.first}');
  }
  final names = <String>{};
  for (final declaration in result.unit.declarations) {
    switch (declaration) {
      case FunctionDeclaration(:final name):
        names.add(name.lexeme);
      case TopLevelVariableDeclaration(:final variables):
        for (final v in variables.variables) {
          names.add(v.name.lexeme);
        }
      default:
        break;
    }
  }
  return names;
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
