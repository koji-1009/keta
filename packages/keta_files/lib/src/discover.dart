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
    this.middleware = const [],
  });

  /// The import path relative to the manifest, e.g. `routes/users/_id.dart`.
  final String importPath;

  /// The import alias, e.g. `$users_id`.
  final String prefix;

  /// The URL this file's location denotes, as parts: `['users', ':id']`. A
  /// `:`-prefixed part is a capture. Empty means `/`.
  final List<String> template;

  /// The directory-scoped middleware this file falls under, outermost first:
  /// the `_middleware.dart` files on the path from `routes/` down to this file,
  /// root-first. Empty for a route under no middleware directory. The generator
  /// hands this to [Exported.bind] so each scope wraps the leaf in nesting
  /// order.
  final List<MiddlewareFile> middleware;

  /// The URL, for humans and for error messages.
  String get url => template.isEmpty ? '/' : '/${template.join('/')}';
}

/// A `_middleware.dart` file: where it sits, and the subtree its directory
/// scopes. The tree is the truth — a middleware file's directory *is* its
/// scope, the same way a route file's location is its URL. Nothing inside the
/// file names the scope; look at where the file sits.
///
/// What it *contributes* is not here, for the same reason [RouteFile] does not
/// carry what a route serves: the file's `scoped` is a typed [ScopedMiddleware]
/// value, and the compiler checks its shape at the binding line the generator
/// emits. A generator that parsed the file to find the middleware would be
/// re-deriving by string matching what the type system already guarantees.
class MiddlewareFile {
  const MiddlewareFile({
    required this.importPath,
    required this.prefix,
    required this.dir,
    required this.scope,
  });

  /// The import path relative to the manifest, e.g. `routes/admin/_middleware.dart`.
  final String importPath;

  /// The import alias, e.g. `$mw$admin`. Two `$`s, so it lives in a namespace no
  /// route alias (one `$`, then identifier characters) can ever reach — a route
  /// file and a middleware file are aliased apart by construction, not by luck.
  final String prefix;

  /// The raw directory segments this file sits in — `['users', '_id']` for
  /// `routes/users/_id/_middleware.dart`, `const []` for the root. Raw (the
  /// `_id` form, not `:id`) because scoping is a prefix test against a route's
  /// raw directory, and both sides must speak the same alphabet.
  final List<String> dir;

  /// The subtree this scopes, as URL parts: `['users', ':id']`. For humans and
  /// for the check that names a middleware file scoping nothing.
  final List<String> scope;

  /// The subtree URL this scopes, for messages.
  String get url => scope.isEmpty ? '/' : '/${scope.join('/')}';
}

/// The two kinds of file the tree holds: the routes, and the `_middleware.dart`
/// files that scope middleware over them. One walk produces both, so a route's
/// [RouteFile.middleware] chain and the [middleware] list share object identity
/// — the same alias travels to the import and to every binding that uses it.
class Discovery {
  const Discovery({required this.routes, required this.middleware});

  /// The route files, sorted by URL.
  final List<RouteFile> routes;

  /// Every `_middleware.dart` file, sorted by the subtree it scopes.
  final List<MiddlewareFile> middleware;
}

/// The reserved filename that marks a directory-scoped middleware file rather
/// than a route. It must be carved out *before* capture interpretation: a
/// leading `_` otherwise reads as a capture (`_id` → `:id`), and this bare-ish
/// name would either become the `:middleware` route nobody wrote or, were it
/// spelled `_.dart`, be rejected as a nameless capture. Its directory is its
/// scope; the file is not a URL at all.
const _middlewareFilename = '_middleware.dart';

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
}) => discover(routesDir, importBase: importBase).routes;

/// The route files and the `_middleware.dart` files under [routesDir], from one
/// walk of the tree. A `_middleware.dart` file is never a route — its directory
/// is its scope — so it is partitioned out before any capture interpretation
/// and surfaced as a [MiddlewareFile] with the subtree it scopes.
///
/// Each route's [RouteFile.middleware] is the outer→inner chain of middleware
/// files whose directory is an ancestor of (or equal to) the route's own — root
/// scope first, deepest last. A middleware file scopes a route iff its directory
/// is a prefix of the route's directory, so `routes/admin/_middleware.dart`
/// scopes every route under `routes/admin/`, and `routes/users/_id/_middleware.dart`
/// scopes the capture subtree.
Discovery discover(String routesDir, {String importBase = 'routes'}) {
  final dir = Directory(routesDir);
  if (!dir.existsSync()) {
    return const Discovery(routes: [], middleware: []);
  }

  final rels =
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .map(
            (f) => p.url.joinAll(p.split(p.relative(f.path, from: routesDir))),
          )
          .toList()
        ..sort();

  // Middleware files first, so a route can find the scopes it falls under.
  final usedMw = <String>{};
  final middleware = <MiddlewareFile>[];
  for (final rel in rels) {
    if (p.url.basename(rel) != _middlewareFilename) continue;
    final segments = rel.split('/');
    final dirSegments = segments.sublist(0, segments.length - 1);
    // The scope's URL parts: a capture directory (`_id`) scopes `:id`. Reusing
    // the same interpretation a route path gets means a directory named just
    // `_` is refused here too, rather than yielding a nameless scope.
    final scope = [for (final s in dirSegments) _captureOrLiteral(s, rel)];
    middleware.add(
      MiddlewareFile(
        importPath: p.url.join(importBase, rel),
        prefix: _uniquePrefix(_middlewareAliasFor(scope), usedMw),
        dir: dirSegments,
        scope: scope,
      ),
    );
  }

  final used = <String>{};
  final byUrl = <String, String>{};
  final result = <RouteFile>[];
  for (final rel in rels) {
    if (p.url.basename(rel) == _middlewareFilename) continue;
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
    final segments = rel.split('/');
    final routeDir = segments.sublist(0, segments.length - 1);
    result.add(
      RouteFile(
        importPath: p.url.join(importBase, rel),
        prefix: _uniquePrefix(_aliasFor(template), used),
        template: template,
        // Outermost first: sort the applicable scopes by depth, so root wraps
        // admin wraps the handler. `middleware` is already sorted by path, but
        // depth is the ordering that matters and two scopes never tie (a tie
        // would be two `_middleware.dart` in one directory, which cannot exist).
        middleware:
            [
              for (final m in middleware)
                if (_isPrefix(m.dir, routeDir)) m,
            ]..sort((a, b) => a.dir.length.compareTo(b.dir.length)),
      ),
    );
  }
  result.sort((a, b) => a.url.compareTo(b.url));
  middleware.sort((a, b) => a.url.compareTo(b.url));
  return Discovery(routes: result, middleware: middleware);
}

/// The middleware files no route falls under — dead weight: a `_middleware.dart`
/// whose directory scopes nothing beneath it, so its `scoped` never wraps a
/// handler. Tolerated by discovery (a scope can legitimately be added before the
/// routes it will guard), but surfaced by `keta_files:check` as its own named
/// condition, because a scope silently guarding nothing is exactly the quiet
/// failure this package exists to make loud.
///
/// Referenced middleware is exactly what the routes point at, by object
/// identity — the same test the generated imports use — so this is its
/// complement.
List<MiddlewareFile> orphanMiddleware(
  List<RouteFile> routes,
  List<MiddlewareFile> middleware,
) {
  final referenced = {
    for (final r in routes)
      for (final m in r.middleware) m.importPath,
  };
  return [
    for (final m in middleware)
      if (!referenced.contains(m.importPath)) m,
  ];
}

/// Whether [prefix] is a leading run of [path] — the directory-scope test: a
/// middleware directory scopes a route directory when it is that directory or
/// one of its ancestors.
bool _isPrefix(List<String> prefix, List<String> path) {
  if (prefix.length > path.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (prefix[i] != path[i]) return false;
  }
  return true;
}

/// A middleware file's import alias: `$mw$` + the subtree's own words, the root
/// scope being `$mw$root`. The doubled `$` puts it in a namespace no route alias
/// occupies — a route alias is a single `$` then identifier characters, so it
/// can never contain a second `$` — which is why a middleware file and a route
/// file can share the tree without their aliases ever colliding.
String _middlewareAliasFor(List<String> scope) {
  final words = [
    for (final part in scope) part.startsWith(':') ? part.substring(1) : part,
  ];
  return '\$mw\$${_sanitize(words.isEmpty ? 'root' : words.join('_'))}';
}

/// The URL parts a relative route-file path denotes.
List<String> _templateOf(String rel) {
  final stem = rel.substring(0, rel.length - '.dart'.length);
  final parts = stem.split('/');
  if (parts.last == 'index') parts.removeLast();
  return [for (final part in parts) _captureOrLiteral(part, rel)];
}

/// A capture (`_id` → `:id`) or a literal path segment. A bare `_` — a file or
/// directory named just an underscore — captures nothing: there is no name
/// left after stripping the leading `_`. Silently emitting an empty capture
/// name would be the one place this package generates a broken URL instead of
/// failing loud, so it is rejected here the same way two files claiming one
/// URL are.
String _captureOrLiteral(String part, String rel) {
  if (part == '_') {
    throw FormatException(
      '"$rel" has a segment that is just "_" with no name after it; '
      'a capture needs a name (e.g. "_id"), so name it or drop the '
      'underscore',
    );
  }
  return part.startsWith('_') ? ':${part.substring(1)}' : part;
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
