import 'dart:io';

import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

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
}
