import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

RouteFile file({
  required String importPath,
  required String prefix,
  required List<String> template,
  List<String> methods = const ['get'],
  Set<String> docs = const {},
  bool declaresCaptures = false,
}) => RouteFile(
  importPath: importPath,
  prefix: prefix,
  template: template,
  methods: methods,
  docs: docs,
  declaresCaptures: declaresCaptures,
);

const _manifest = '''
void register(App<Env> app) {
  // keta_files:routes
  // keta_files:end
}
''';

const _imports = '''
// keta_files:imports
// keta_files:end
$_manifest''';

void main() {
  group('the manifest reads as the route table', () {
    test('the URL is written into the binding, in the tree\'s own words', () {
      final out = syncManifest(_imports, [
        file(
          importPath: 'routes/users/_id.dart',
          prefix: r'$users_id',
          template: ['users', ':id'],
          docs: {'get'},
        ),
      ]);
      expect(out, contains("import 'routes/users/_id.dart' as \$users_id;"));
      expect(out, contains("routeSegments(const ['users', ':id'])"));
      expect(out, contains(r'$users_id.get'));
      expect(out, contains(r'doc: $users_id.getDoc'));
    });

    test('a verb without a doc binds without one', () {
      final out = syncManifest(_imports, [
        file(importPath: 'routes/x.dart', prefix: r'$x', template: ['x']),
      ]);
      expect(out, isNot(contains('doc:')));
    });

    test('captures is passed only by a file that declares it', () {
      final with_ = syncManifest(_imports, [
        file(
          importPath: 'routes/_id.dart',
          prefix: r'$id',
          template: [':id'],
          declaresCaptures: true,
        ),
      ]);
      final without = syncManifest(_imports, [
        file(importPath: 'routes/_id.dart', prefix: r'$id', template: [':id']),
      ]);
      expect(with_, contains(r"routeSegments(const [':id'], $id.captures)"));
      expect(without, contains("routeSegments(const [':id'])"));
    });

    test('the root is an empty template, not an empty string', () {
      final out = syncManifest(_imports, [
        file(importPath: 'routes/index.dart', prefix: r'$index', template: []),
      ]);
      expect(out, contains('routeSegments(const <String>[])'));
    });

    test('every verb a file serves gets its own binding', () {
      final out = syncManifest(_imports, [
        file(
          importPath: 'routes/users.dart',
          prefix: r'$users',
          template: ['users'],
          methods: ['get', 'post'],
        ),
      ]);
      expect(out, contains(r'app.get('));
      expect(out, contains(r'app.post('));
    });
  });

  group('the generator refuses to corrupt what it cannot parse', () {
    test('a start marker with no end', () {
      expect(
        () => syncManifest('// keta_files:imports\n$_manifest', const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('a duplicated start marker', () {
      expect(
        () => syncManifest(
          '// keta_files:imports\n// keta_files:end\n$_imports',
          const [],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('overlapping regions', () {
      expect(
        () => syncManifest(
          '// keta_files:imports\n// keta_files:routes\n// keta_files:end\n',
          const [],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a missing marker', () {
      expect(
        () => syncManifest('void register(App app) {}', const []),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('drift is caught', () {
    final f = file(
      importPath: 'routes/x.dart',
      prefix: r'$x',
      template: ['x'],
      docs: {'get'},
    );

    test('a synced manifest is settled', () {
      final synced = syncManifest(_imports, [f]);
      expect(unregistered(synced, [f]), isEmpty);
      // Idempotent, or "synced" would mean nothing.
      expect(syncManifest(synced, [f]), synced);
    });

    test('a file bound nowhere is reported', () {
      expect(unregistered(_imports, [f]), [f]);
    });

    test('a mention outside the regions does not count', () {
      // A route named in a comment is not a route served.
      const decoy =
          "// import 'routes/x.dart' as \$x;\n"
          '$_imports';
      expect(unregistered(decoy, [f]), [f]);
    });
  });

  group('routeSegments turns a template into a path', () {
    test('a capture the file does not mention is a string', () {
      final segments = routeSegments(const ['users', ':id']);
      expect((segments[0] as LiteralSegment).value, 'users');
      final capture = (segments[1] as CaptureSegment).capture;
      expect(capture.name, 'id');
      expect(capture.schema, {'type': 'string'});
    });

    test('a declared capture supplies the type, and is named by the tree', () {
      final segments = routeSegments(
        const [':index'],
        const {'index': integer},
      );
      final capture = (segments.single as CaptureSegment).capture;
      // The name comes from the file's location; the declaration is about the
      // type alone, so the two cannot disagree.
      expect(capture.name, 'index');
      expect(capture.schema, {'type': 'integer'});
    });

    test('a declaration for a part the tree does not have is inert', () {
      final segments = routeSegments(const ['users'], const {'id': integer});
      expect(segments.single, isA<LiteralSegment>());
    });

    test('the root is no segments', () {
      expect(routeSegments(const []), isEmpty);
    });
  });
}
