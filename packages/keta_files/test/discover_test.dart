/// Filesystem discovery of the routes tree: file-to-URL mapping, alias
/// generation, directory-scoped middleware chains and their orphan check,
/// and symlink-cycle safety. (Binding/export and manifest emission have
/// their own files, export_test.dart and manifest_test.dart.)
library;

import 'dart:io';

import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

/// The routes half of [discover] — this suite's subject is the file→URL
/// mapping, so most cases never look at the middleware half.
List<RouteFile> discoverRouteFiles(String routesDir) =>
    discover(routesDir).routes;

/// Builds a routes tree on disk. Values are file bodies; a bare `get` export is
/// enough to be a route.
Directory tree(Map<String, String> files) {
  final dir = Directory.systemTemp.createTempSync('keta_files');
  addTearDown(() => dir.deleteSync(recursive: true));
  files.forEach((path, body) {
    final file = File('${dir.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  });
  return dir;
}

/// Discovery never reads a file's contents — what it serves is its `exported`'s
/// type to state. A body is only here so the file exists.
const _any = '// a route';

void main() {
  group('a location denotes a URL', () {
    test('the whole mapping', () {
      final dir = tree({
        'index.dart': _any,
        'health.dart': _any,
        'users.dart': _any,
        'users/_id.dart': _any,
        'users/_uid/tags/_index.dart': _any,
        'admin/ping.dart': _any,
      });
      expect(
        {for (final f in discoverRouteFiles(dir.path)) f.importPath: f.url},
        {
          'routes/index.dart': '/',
          'routes/health.dart': '/health',
          'routes/users.dart': '/users',
          'routes/users/_id.dart': '/users/:id',
          'routes/users/_uid/tags/_index.dart': '/users/:uid/tags/:index',
          'routes/admin/ping.dart': '/admin/ping',
        },
      );
    });

    test('index denotes its directory, not a segment called index', () {
      final dir = tree({'users/index.dart': _any});
      expect(discoverRouteFiles(dir.path).single.url, '/users');
    });

    test('two files claiming one URL is refused, not merged', () {
      // `users.dart` and `users/index.dart` both say /users, and nothing in the
      // tree says which wins. Answering arbitrarily would be worse than asking.
      final dir = tree({'users.dart': _any, 'users/index.dart': _any});
      expect(
        () => discoverRouteFiles(dir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('users.dart'), contains('/users')),
          ),
        ),
      );
    });

    test('the order is the tree, not the directory listing', () {
      final dir = tree({'z.dart': _any, 'a.dart': _any, 'm/_id.dart': _any});
      expect(discoverRouteFiles(dir.path).map((f) => f.url), [
        '/a',
        '/m/:id',
        '/z',
      ]);
    });

    test('a missing tree is empty, not an error', () {
      expect(discoverRouteFiles('/nowhere/at/all'), isEmpty);
    });

    test('a file named "_" captures nothing and is refused', () {
      // `_.dart` strips to an empty capture name — silently emitting `:` would
      // be a URL nobody asked for, so it fails loud instead, naming the file.
      final dir = tree({'_.dart': _any});
      expect(
        () => discoverRouteFiles(dir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('_.dart'),
          ),
        ),
      );
    });

    test('a directory named "_" is refused the same way', () {
      final dir = tree({'_/users.dart': _any});
      expect(
        () => discoverRouteFiles(dir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('_/users.dart'),
          ),
        ),
      );
    });
  });

  group('generated aliases cannot collide with the app', () {
    test('every alias is \$-led', () {
      final dir = tree({'metrics.dart': _any, 'users/_id.dart': _any});
      expect(discoverRouteFiles(dir.path).map((f) => f.prefix), [
        r'$metrics',
        r'$users_id',
      ]);
    });

    test('a URL word that is a reserved word needs no escaping', () {
      // `$get` is not `get`, so the alias is the URL's own word either way.
      final dir = tree({'get.dart': _any, 'class/new.dart': _any});
      expect(discoverRouteFiles(dir.path).map((f) => f.prefix), [
        r'$class_new',
        r'$get',
      ]);
    });

    test('two URLs sanitizing to one alias are still distinct', () {
      final dir = tree({'a-b.dart': _any, 'a_b.dart': _any});
      final prefixes = discoverRouteFiles(dir.path).map((f) => f.prefix);
      expect(prefixes.toSet(), hasLength(2));
      expect(prefixes, everyElement(startsWith(r'$a_b')));
    });
  });

  group('a directory scopes middleware over the routes beneath it', () {
    test('_middleware.dart is a scope, never a route', () {
      // A leading `_` reads as a capture everywhere else (`_id` → `:id`); the
      // middleware filename is carved out before that interpretation, so it
      // never becomes the `:middleware` route nobody wrote, and never lands in
      // the route list at all.
      final found = discover(
        tree({'admin/_middleware.dart': _any, 'admin/ping.dart': _any}).path,
      );
      expect(found.routes.map((f) => f.url), ['/admin/ping']);
      expect(found.middleware.map((m) => m.importPath), [
        'routes/admin/_middleware.dart',
      ]);
    });

    test('a route carries the outer→inner chain of the scopes above it', () {
      // routes/admin/audit/log.dart falls under routes/_middleware.dart and
      // routes/admin/_middleware.dart — root first, then admin, then the file.
      final found = discover(
        tree({
          '_middleware.dart': _any,
          'admin/_middleware.dart': _any,
          'admin/audit/log.dart': _any,
        }).path,
      );
      final log = found.routes.single;
      expect(log.url, '/admin/audit/log');
      expect(log.middleware.map((m) => m.url), ['/', '/admin']);
    });

    test('a scope reaches only its own subtree, not a sibling', () {
      final found = discover(
        tree({
          'admin/_middleware.dart': _any,
          'admin/ping.dart': _any,
          'public/health.dart': _any,
        }).path,
      );
      final byUrl = {for (final r in found.routes) r.url: r.middleware};
      expect(byUrl['/admin/ping']!.map((m) => m.url), ['/admin']);
      expect(byUrl['/public/health'], isEmpty);
    });

    test('a scope under a capture directory scopes the capture subtree', () {
      final found = discover(
        tree({
          'users/_id/_middleware.dart': _any,
          'users/_id/posts.dart': _any,
        }).path,
      );
      final posts = found.routes.single;
      expect(posts.url, '/users/:id/posts');
      final scope = posts.middleware.single;
      expect(scope.url, '/users/:id');
      // The scope's raw directory is what the prefix test runs on, in the
      // filename's own alphabet — `:id` is only the human-facing rendering.
      expect(scope.dir, ['users', '_id']);
    });

    test('the root scope wraps every route, the root route included', () {
      final found = discover(
        tree({
          '_middleware.dart': _any,
          'index.dart': _any,
          'health.dart': _any,
        }).path,
      );
      for (final r in found.routes) {
        expect(
          r.middleware.map((m) => m.url),
          ['/'],
          reason: '${r.url} falls under the root scope',
        );
      }
    });

    test('middleware aliases are \$mw\$-led and cannot meet a route alias', () {
      // A route alias is one `$` then identifier characters; a middleware alias
      // carries a second `$`, so the two namespaces cannot intersect — even when
      // a route is literally named `mw`.
      final found = discover(
        tree({
          '_middleware.dart': _any,
          'admin/_middleware.dart': _any,
          'mw.dart': _any,
          'admin/ping.dart': _any,
        }).path,
      );
      expect(found.middleware.map((m) => m.prefix), [
        r'$mw$root',
        r'$mw$admin',
      ]);
      expect(found.routes.map((f) => f.prefix), containsAll([r'$mw']));
      final all = [
        ...found.routes.map((f) => f.prefix),
        ...found.middleware.map((m) => m.prefix),
      ];
      expect(
        all.toSet(),
        hasLength(all.length),
        reason: 'all aliases distinct',
      );
    });

    test('two scopes sanitizing to one alias stay distinct', () {
      final found = discover(
        tree({
          'a-b/_middleware.dart': _any,
          'a-b/x.dart': _any,
          'a_b/_middleware.dart': _any,
          'a_b/y.dart': _any,
        }).path,
      );
      final prefixes = found.middleware.map((m) => m.prefix).toList();
      expect(prefixes.toSet(), hasLength(2));
      expect(prefixes, everyElement(startsWith(r'$mw$a_b')));
    });

    test('a scope guarding nothing beneath it is an orphan', () {
      // Dead weight: the file exists but no route falls under it. Tolerated by
      // discovery, named by the check.
      final found = discover(
        tree({'admin/_middleware.dart': _any, 'public/health.dart': _any}).path,
      );
      final orphans = orphanMiddleware(found.routes, found.middleware);
      expect(orphans.map((m) => m.url), ['/admin']);
    });

    test('a scope with a route under it is not an orphan', () {
      final found = discover(
        tree({'admin/_middleware.dart': _any, 'admin/ping.dart': _any}).path,
      );
      expect(orphanMiddleware(found.routes, found.middleware), isEmpty);
    });

    // DUPLICATE removed: "a middleware file is not a route, so it is never
    // unregistered" round-tripped this same tree through manifest.dart's
    // `unregistered()` to re-prove a fact already pinned directly above by
    // "_middleware.dart is a scope, never a route" (found.routes excludes
    // the middleware file), while `unregistered()`'s own contract — that a
    // manifest missing a route is reported — is separately and more simply
    // pinned by manifest_test.dart's "a file bound nowhere is reported". The
    // combination proved nothing beyond what those two already cover, and
    // `unregistered` is manifest.dart's function, out of this file's charter.
  });

  group('a symlink into the tree is not walked', () {
    test('a cycle is not followed, not looped, not thrown', () {
      // A route tree is authored files; a symlink into it is at best an
      // alias for truth that lives elsewhere. Point one at its own ancestor
      // and the cycle is real: `listSync`'s default of following links would
      // walk it forever (or until the OS's own link-depth limit throws).
      // `followLinks: false` makes the link itself the listing entry instead
      // of something to descend into, so it is dropped by `whereType<File>`
      // the same as a plain directory is.
      final dir = tree({'admin/ping.dart': _any});
      final loop = Link('${dir.path}/loop');
      try {
        loop.createSync(dir.path);
      } on FileSystemException {
        // Some sandboxes and filesystems refuse to create a symlink at all
        // (no privilege, or no support for them). The behavior under test is
        // how discovery walks a link that exists, not whether one can be
        // made to exist here, so skip rather than fail.
        markTestSkipped('filesystem refused to create a symlink');
        return;
      }
      expect(discoverRouteFiles(dir.path).map((f) => f.url), ['/admin/ping']);
    });
  });
}
