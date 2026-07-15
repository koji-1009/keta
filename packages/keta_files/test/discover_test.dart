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

const _get = 'Object? get(Object? c) => null;';

void main() {
  group('a location denotes a URL', () {
    test('the whole mapping', () {
      final dir = tree({
        'index.dart': _get,
        'health.dart': _get,
        'users.dart': _get,
        'users/_id.dart': _get,
        'users/_uid/tags/_index.dart': _get,
        'admin/ping.dart': _get,
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
      final dir = tree({'users/index.dart': _get});
      expect(discoverRouteFiles(dir.path).single.url, '/users');
    });

    test('two files claiming one URL is refused, not merged', () {
      // `users.dart` and `users/index.dart` both say /users, and nothing in the
      // tree says which wins. Answering arbitrarily would be worse than asking.
      final dir = tree({'users.dart': _get, 'users/index.dart': _get});
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

    test('a file serving nothing is refused', () {
      // It would sit in the tree looking like a route and answer nothing.
      final dir = tree({'health.dart': 'const x = 1;'});
      expect(
        () => discoverRouteFiles(dir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('exports no HTTP method'),
          ),
        ),
      );
    });

    test('the order is the tree, not the directory listing', () {
      final dir = tree({'z.dart': _get, 'a.dart': _get, 'm/_id.dart': _get});
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

  group('what a file serves', () {
    test('one export is one verb, in method order', () {
      final dir = tree({
        'users.dart': 'Object? post(Object? c) => null;\n$_get',
      });
      expect(discoverRouteFiles(dir.path).single.methods, ['get', 'post']);
    });

    test('a <verb>Doc is picked up per verb', () {
      final dir = tree({
        'users.dart':
            '$_get\nconst getDoc = 1;\nObject? post(Object? c) => null;',
      });
      final file = discoverRouteFiles(dir.path).single;
      expect(file.docs, {'get'});
    });

    test('captures is noticed only when declared', () {
      final withIt = tree({'_id.dart': '$_get\nconst captures = {};'});
      final without = tree({'_id.dart': _get});
      expect(discoverRouteFiles(withIt.path).single.declaresCaptures, isTrue);
      expect(discoverRouteFiles(without.path).single.declaresCaptures, isFalse);
    });

    test('a file that does not parse is named, not skipped', () {
      final dir = tree({'broken.dart': 'this is not dart'});
      expect(
        () => discoverRouteFiles(dir.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('broken.dart'),
          ),
        ),
      );
    });
  });

  group('generated aliases cannot collide with the app', () {
    test('every alias is \$-led', () {
      final dir = tree({'metrics.dart': _get, 'users/_id.dart': _get});
      expect(discoverRouteFiles(dir.path).map((f) => f.prefix), [
        r'$metrics',
        r'$users_id',
      ]);
    });

    test('a URL word that is a reserved word needs no escaping', () {
      // `$get` is not `get`, so the alias is the URL's own word either way.
      final dir = tree({'get.dart': _get, 'class/new.dart': _get});
      expect(discoverRouteFiles(dir.path).map((f) => f.prefix), [
        r'$class_new',
        r'$get',
      ]);
    });

    test('two URLs sanitizing to one alias are still distinct', () {
      final dir = tree({'a-b.dart': _get, 'a_b.dart': _get});
      final prefixes = discoverRouteFiles(dir.path).map((f) => f.prefix);
      expect(prefixes.toSet(), hasLength(2));
      expect(prefixes, everyElement(startsWith(r'$a_b')));
    });
  });
}
