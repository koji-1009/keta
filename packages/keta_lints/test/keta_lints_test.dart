/// The small, independent lint rules that don't belong to the canonical/
/// scaffold/drift cluster (route captures, internal `await`, tx-ordering,
/// declared query parameters), plus the shared infra they and the CLI sit on:
/// stable diagnostic ids (including cross-checkout portability), Dart literal
/// escaping, and loading a YAML document into plain collections.
library;

import 'dart:io';

import 'package:keta_lints/keta_lints.dart';
import 'package:keta_lints/src/dart_literal.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('routeDiagnostics', () {
    test('a matched capture is clean', () {
      const source = '''
void register(app) {
  app.get('/users/:id', (c) => c.text(c.param('id')));
}
''';
      expect(routeDiagnostics(source), isEmpty);
    });

    test('an unused capture is keta_capture_unused', () {
      const source = '''
void register(app) {
  app.get('/users/:id', (c) => c.text('x'));
}
''';
      final d = routeDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_capture_unused');
      expect(d.single.message, contains(':id'));
    });

    test('an unknown param is keta_param_unknown', () {
      const source = '''
void register(app) {
  app.get('/users/:id', (c) => c.text(c.param('name')));
}
''';
      final rules = routeDiagnostics(source).map((d) => d.rule).toSet();
      expect(rules, containsAll(['keta_param_unknown', 'keta_capture_unused']));
    });
  });

  group('internalAwaitDiagnostics', () {
    test('await-free code is clean', () {
      const source = 'int add(int a, int b) => a + b;';
      expect(internalAwaitDiagnostics(source), isEmpty);
    });

    test('an await is flagged', () {
      const source =
          'Future<void> f() async { await g(); }\nFuture<void> g() async {}';
      final d = internalAwaitDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_internal_await');
    });

    test('a justified await is suppressed', () {
      const source = '''
Future<void> f() async {
  // keta:allow-await
  await g();
}
Future<void> g() async {}
''';
      expect(internalAwaitDiagnostics(source), isEmpty);
    });

    test('an await-for is flagged', () {
      const source =
          'Future<void> f(Stream<int> s) async {\n  await for (final _ in s) {}\n}';
      final d = internalAwaitDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_internal_await');
      expect(d.single.message, contains('await on line 2'));
    });

    test('a justified await-for is suppressed', () {
      const source =
          'Future<void> f(Stream<int> s) async {\n  // keta:allow-await\n  await for (final _ in s) {}\n}';
      expect(internalAwaitDiagnostics(source), isEmpty);
    });
  });

  group('txOrderDiagnostics', () {
    test('use(tx()) before use(recover()) is flagged', () {
      const source = 'void register(app) { app..use(tx())..use(recover()); }';
      final d = txOrderDiagnostics(source);
      expect(d, hasLength(1));
      expect(d.single.rule, 'keta_tx_outside_recover');
    });

    test('use(recover()) before use(tx()) is clean', () {
      const source = '''
void register() {
  final app = App<Env>()..use(accessLog())..use(recover())..use(tx());
}
''';
      expect(txOrderDiagnostics(source), isEmpty);
    });

    test('use(tx()) without recover() is not flagged', () {
      const source = 'void register(app) { app..use(tx()); }';
      expect(txOrderDiagnostics(source), isEmpty);
    });
  });

  group('diagnosticId', () {
    test('is stable and 16 hex chars', () {
      final a = diagnosticId('lib/x.dart', 'GET /x', 'keta_route_conflict');
      final b = diagnosticId('lib/x.dart', 'GET /x', 'keta_route_conflict');
      expect(a, b);
      expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(
        a,
        isNot(diagnosticId('lib/y.dart', 'GET /x', 'keta_route_conflict')),
      );
    });

    test('the stable id keys on the path WITHIN the enclosing package, so two '
        'checkouts at different absolute locations hash the same file to one id '
        '(the cross-machine portability the id exists for)', () {
      final a = Directory.systemTemp.createTempSync('keta_lints_ida');
      final b = Directory.systemTemp.createTempSync('keta_lints_idb');
      addTearDown(() {
        a.deleteSync(recursive: true);
        b.deleteSync(recursive: true);
      });
      for (final dir in [a, b]) {
        File(
          p.join(dir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: fixture\n');
        Directory(p.join(dir.path, 'lib')).createSync();
        File(
          p.join(dir.path, 'lib', 'foo.dart'),
        ).writeAsStringSync('class X {}');
      }
      final relA = packageRelativePath(p.join(a.path, 'lib', 'foo.dart'));
      final relB = packageRelativePath(p.join(b.path, 'lib', 'foo.dart'));
      expect(relA, 'lib/foo.dart');
      expect(relB, 'lib/foo.dart');
      expect(
        diagnosticId(relA, 'X', 'keta_canonical_missing'),
        diagnosticId(relB, 'X', 'keta_canonical_missing'),
      );
    });

    test('a path with no enclosing pubspec falls back to the basename', () {
      final dir = Directory.systemTemp.createTempSync('keta_lints_noroot');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'loose.dart'))
        ..writeAsStringSync('class Y {}');
      // No pubspec.yaml anywhere above the temp file, so the basename is the
      // most stable key available.
      expect(packageRelativePath(file.path), 'loose.dart');
    });
  });

  group('dartLiteral', () {
    test('a single-line \$ value takes the raw-string path', () {
      expect(dartLiteral(r'$ref'), r"r'$ref'");
      expect(
        dartLiteral({r'$ref': '#/components/schemas/X'}),
        r"{r'$ref': '#/components/schemas/X'}",
      );
    });
    test('escapes backslash, quote, and control chars', () {
      expect(dartLiteral(r'a\b'), r"'a\\b'");
      expect(dartLiteral("it's"), r"'it\'s'");
      expect(dartLiteral('a\rb'), r"'a\rb'");
      expect(dartLiteral('a\tb'), r"'a\tb'");
    });
    test('a value with both \$ and a quote takes the escape path', () {
      expect(dartLiteral(r"$a's"), r"'\$a\'s'");
    });
    test('a value with \$ and a backslash takes the escape path', () {
      expect(dartLiteral('\$a\\'), r"'\$a\\'");
    });
    test('a multi-line \$ value cannot be raw', () {
      expect(dartLiteral('\$a\nb'), r"'\$a\nb'");
    });
    test('dartStringLiteral shares the same edges', () {
      expect(dartStringLiteral(r'$ref'), r"r'$ref'");
      expect(dartStringLiteral("a'b\n"), r"'a\'b\n'");
    });
    test('a non-JSON value falls back to an escaped toString', () {
      expect(dartLiteral(const Duration(seconds: 1)), "'0:00:01.000000'");
    });
    test('scalars, lists, and non-string map keys', () {
      expect(dartLiteral(null), 'null');
      expect(dartLiteral([1, 'a']), "[1, 'a']");
      expect(dartLiteral({1: 'v'}), "{'1': 'v'}");
    });
  });

  group('yaml_plain', () {
    test('parses a mapping document into plain collections', () {
      final doc = loadYamlDocument(
        'info:\n  title: t\ntags:\n  - a\n  - 2\nflag: true\n',
      );
      expect(doc['info'], {'title': 't'});
      expect(doc['info'], isA<Map<String, Object?>>());
      expect(doc['tags'], ['a', 2]);
      expect(doc['flag'], true);
    });
    test('non-string keys are stringified', () {
      expect(loadYamlDocument('1: a'), {'1': 'a'});
    });
    test('a non-mapping root is a FormatException', () {
      expect(() => loadYamlDocument('- a\n- b'), throwsFormatException);
      expect(() => loadYamlDocument('just a scalar'), throwsFormatException);
      expect(() => loadYamlDocument(''), throwsFormatException);
    });
    test('yamlToPlain passes non-YAML nodes through', () {
      expect(yamlToPlain(42), 42);
      expect(yamlToPlain(null), isNull);
    });
  });

  group('query lint', () {
    test('flags a c.query access not declared in RouteDoc.query', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.query<int>('page')}),
      doc: const RouteDoc(query: [QueryParam('other', integer)]));
}
''';
      final d = queryDiagnostics(source);
      expect(d.single.rule, 'keta_query_undeclared');
      expect(d.single.message, contains('page'));
    });

    test('flags reading a required query with tryQuery (drift)', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.tryQuery<int>('page')}),
      doc: const RouteDoc(query: [QueryParam('page', integer, required: true)]));
}
''';
      expect(queryDiagnostics(source).single.rule, 'keta_query_drift');
    });

    test('a declared, correctly-read query is clean', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.query<int>('page')}),
      doc: const RouteDoc(query: [QueryParam('page', integer, required: true)]));
}
''';
      expect(queryDiagnostics(source), isEmpty);
    });

    test('a non-inline doc is not second-guessed', () {
      const source = '''
void register(app) {
  app.get('/s', (c) => c.json({'p': c.query<int>('page')}), doc: userDoc);
}
''';
      expect(queryDiagnostics(source), isEmpty);
    });
  });
}
