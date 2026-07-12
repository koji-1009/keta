import 'dart:io';

import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

const _manifest = '''
import 'package:keta/keta.dart';
import 'env.dart';
// keta_files:imports
// keta_files:end

void registerRoutes(App<Env> app) {
  // keta_files:routes
  // keta_files:end
}
''';

void main() {
  test('syncManifest fills both marked regions, indentation preserved', () {
    final files = [
      const RouteFile('routes/health.dart', 'health'),
      const RouteFile('routes/users.dart', 'users'),
    ];
    final output = syncManifest(_manifest, files);

    expect(output, contains("import 'routes/health.dart' as health;"));
    expect(output, contains("import 'routes/users.dart' as users;"));
    expect(output, contains('  users.register(app);'));
    expect(output, contains('  health.register(app);'));
    // Code outside the markers is untouched.
    expect(output, contains('void registerRoutes(App<Env> app) {'));
    // Idempotent.
    expect(syncManifest(output, files), output);
  });

  test('syncManifest without markers is a FormatException', () {
    expect(
      () => syncManifest('void main() {}', const []),
      throwsA(isA<FormatException>()),
    );
  });

  test('unregistered lists files missing from the manifest', () {
    final files = [
      const RouteFile('routes/a.dart', 'a'),
      const RouteFile('routes/b.dart', 'b'),
    ];
    final synced = syncManifest(_manifest, [files.first]);
    final missing = unregistered(synced, files);
    expect(missing.map((f) => f.prefix), ['b']);
  });

  test('discoverRouteFiles finds dart files with unique prefixes', () {
    final dir = Directory.systemTemp.createTempSync('keta_files');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/users.dart').writeAsStringSync('');
    File('${dir.path}/user-posts.dart').writeAsStringSync('');
    File('${dir.path}/notes.txt').writeAsStringSync('');

    final files = discoverRouteFiles(dir.path);
    expect(files.map((f) => f.prefix), ['user_posts', 'users']);
    expect(files.every((f) => f.importPath.startsWith('routes/')), isTrue);
  });

  group('syncManifest — marker and region edges', () {
    test('a missing end marker is a FormatException naming end', () {
      const source = '// keta_files:imports\n';
      expect(
        () => syncManifest(source, const []),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'marker "// keta_files:imports" has no "// keta_files:end"',
          ),
        ),
      );
    });

    test('a missing start marker has a distinct message', () {
      expect(
        () => syncManifest('void main() {}', const []),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'manifest is missing the "// keta_files:imports" marker',
          ),
        ),
      );
    });

    test('an empty file list clears populated regions but keeps markers', () {
      final populated = syncManifest(_manifest, [
        const RouteFile('routes/a.dart', 'a'),
        const RouteFile('routes/b.dart', 'b'),
      ]);
      final cleared = syncManifest(populated, const []);

      expect(cleared, isNot(contains("import 'routes/")));
      expect(cleared, isNot(contains('.register(app);')));
      expect(cleared, contains('// keta_files:imports'));
      expect(cleared, contains('// keta_files:routes'));
      expect(cleared, contains('// keta_files:end'));
      expect(syncManifest(cleared, const []), cleared); // idempotent
    });

    test('each region inherits its own marker indentation', () {
      const source = '''
    // keta_files:imports
    // keta_files:end
void f(App<Env> app) {
  // keta_files:routes
  // keta_files:end
}
''';
      final output = syncManifest(source, [
        const RouteFile('routes/a.dart', 'a'),
      ]);
      expect(output.split('\n'), contains("    import 'routes/a.dart' as a;"));
      expect(output.split('\n'), contains('  a.register(app);'));
    });

    test('content outside the markers is preserved byte-for-byte', () {
      const header =
          "// weird   spacing\t\nimport 'x.dart';\n// keta_files:imports\n";
      const middle =
          '// keta_files:end\nvoid f() {\n  /* body */\n  // keta_files:routes\n';
      const footer = '  // keta_files:end\n}'; // no trailing newline
      const source = '$header$middle$footer';

      final output = syncManifest(source, [
        const RouteFile('routes/a.dart', 'a'),
      ]);
      expect(
        output,
        '$header'
        "import 'routes/a.dart' as a;\n"
        '$middle'
        '  a.register(app);\n'
        '$footer',
      );
    });
  });

  group('unregistered — region-scoped', () {
    final files = [const RouteFile('routes/a.dart', 'a')];

    // A well-formed manifest with the two managed regions optionally populated.
    String manifest({String imports = '', String routes = ''}) =>
        '// '
        'keta_files:imports\n$imports// keta_files:end\n// keta_files:routes\n'
        '$routes// keta_files:end\n';

    test('an import without a register call counts as unregistered', () {
      final src = manifest(imports: "import 'routes/a.dart' as a;\n");
      expect(unregistered(src, files), files);
    });

    test('a register call without an import counts as unregistered', () {
      final src = manifest(routes: 'a.register(app);\n');
      expect(unregistered(src, files), files);
    });

    test('both an import and a register call means registered', () {
      final src = manifest(
        imports: "import 'routes/a.dart' as a;\n",
        routes: 'a.register(app);\n',
      );
      expect(unregistered(src, files), isEmpty);
    });

    test('a mention in a comment or string literal does not count', () {
      const src =
          "// import 'routes/a.dart' as a; a.register(app);\n"
          'const help = "as a; then a.register(app)";\n'
          '// keta_files:imports\n// keta_files:end\n'
          '// keta_files:routes\n// keta_files:end\n';
      expect(unregistered(src, files), files);
    });

    test('a substring-colliding prefix is not a false positive', () {
      // api_a is registered; plain a must still read as unregistered even
      // though "api_a.register(" contains "a.register(" as a substring.
      final src = manifest(
        imports: "import 'routes/api_a.dart' as api_a;\n",
        routes: 'api_a.register(app);\n',
      );
      expect(unregistered(src, files).map((f) => f.prefix), ['a']);
    });
  });

  group('syncManifest — malformed markers rejected (no silent corruption)', () {
    final one = [const RouteFile('routes/a.dart', 'a')];

    test('a duplicate start marker (e.g. buried in a string) is rejected', () {
      const src =
          'const doc = """\n// keta_files:imports\n""";\n'
          '// keta_files:imports\n// keta_files:end\n'
          '// keta_files:routes\n// keta_files:end\n';
      expect(
        () => syncManifest(src, one),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('appears more than once'),
          ),
        ),
      );
    });

    test('overlapping/interleaved regions are rejected', () {
      const src =
          '// keta_files:routes\n// keta_files:imports\n'
          '// keta_files:end\n// keta_files:end\n';
      expect(
        () => syncManifest(src, one),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('overlaps'),
          ),
        ),
      );
    });
  });

  group('discoverRouteFiles — prefix and filtering edges', () {
    test('colliding sanitized prefixes are suffixed', () {
      final dir = Directory.systemTemp.createTempSync('keta_files');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/user-posts.dart').writeAsStringSync('');
      File('${dir.path}/user_posts.dart').writeAsStringSync('');

      final files = discoverRouteFiles(dir.path);
      // '-' (0x2D) sorts before '_' (0x5F), so user-posts.dart is first.
      expect(files.map((f) => f.prefix), ['user_posts', 'user_posts1']);
      expect(files.map((f) => f.importPath), [
        'routes/user-posts.dart',
        'routes/user_posts.dart',
      ]);
    });

    test('a leading-digit name is prefixed with underscore', () {
      final dir = Directory.systemTemp.createTempSync('keta_files');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/2fa.dart').writeAsStringSync('');

      expect(discoverRouteFiles(dir.path).single.prefix, '_2fa');
    });

    test('reserved-word and empty names become valid identifiers', () {
      final dir = Directory.systemTemp.createTempSync('keta_files');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/if.dart').writeAsStringSync('');
      File('${dir.path}/class.dart').writeAsStringSync('');
      File('${dir.path}/.dart').writeAsStringSync('');

      // '.dart' sorts first (stem ''), then 'class.dart', then 'if.dart'.
      expect(discoverRouteFiles(dir.path).map((f) => f.prefix), [
        'route',
        'class_',
        'if_',
      ]);
    });

    test('a missing directory yields an empty list', () {
      final dir = Directory.systemTemp.createTempSync('keta_files');
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(discoverRouteFiles('${dir.path}/does-not-exist'), isEmpty);
    });

    test('importBase drives the generated import path', () {
      final dir = Directory.systemTemp.createTempSync('keta_files');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/users.dart').writeAsStringSync('');

      final files = discoverRouteFiles(dir.path, importBase: 'src/routes');
      expect(files.single.importPath, 'src/routes/users.dart');
      expect(files.single.prefix, 'users');
    });

    test('discovery is non-recursive and skips directories', () {
      final dir = Directory.systemTemp.createTempSync('keta_files');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/top.dart').writeAsStringSync('');
      Directory('${dir.path}/nested').createSync();
      File('${dir.path}/nested/inner.dart').writeAsStringSync('');
      Directory('${dir.path}/fake.dart').createSync(); // a dir named *.dart

      expect(discoverRouteFiles(dir.path).map((f) => f.prefix), ['top']);
    });
  });
}
