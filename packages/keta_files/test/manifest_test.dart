import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:keta/keta.dart';
import 'package:keta_files/keta_files.dart';
import 'package:test/test.dart';

RouteFile file({
  required String importPath,
  required String prefix,
  required List<String> template,
}) => RouteFile(importPath: importPath, prefix: prefix, template: template);

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
    test('one line per file, and the URL is in it', () {
      final out = syncManifest(_imports, [
        file(
          importPath: 'routes/users/_id.dart',
          prefix: r'$users_id',
          template: ['users', ':id'],
        ),
      ]);
      expect(out, contains("import 'routes/users/_id.dart' as \$users_id;"));
      // The URL, in the tree's own words. What the file answers is absent on
      // purpose: that is its `exported`'s type to say, and the compiler's to
      // check at this very line.
      expect(
        out,
        contains(r"$users_id.exported.bind(app, const ['users', ':id']);"),
      );
    });

    test('a generated import line silences the infos it inherently trips', () {
      // Every generated alias is `$`-led (see `_aliasFor`/`_middlewareAliasFor`
      // in discover.dart) and the region is sorted by URL, not interleaved
      // alphabetically with the file's own imports — both `library_prefixes`
      // and `directives_ordering` are the analyzer noticing exactly that,
      // inherent to this generator's own convention rather than a mistake in
      // any one tree. The generator owns the suppression on the line it
      // writes, so a consuming project never carries a matching
      // `ignore_for_file` the generator did not ask for.
      final out = syncManifest(_imports, [
        file(
          importPath: 'routes/users/_id.dart',
          prefix: r'$users_id',
          template: ['users', ':id'],
        ),
      ]);
      expect(
        out,
        contains(
          "import 'routes/users/_id.dart' as \$users_id; "
          '// ignore: directives_ordering, library_prefixes',
        ),
      );
    });

    test('the root is an empty template, not an empty string', () {
      final out = syncManifest(_imports, [
        file(importPath: 'routes/index.dart', prefix: r'$index', template: []),
      ]);
      expect(out, contains(r'$index.exported.bind(app, const <String>[]);'));
    });

    test('a segment with a quote, dollar, or backslash escapes cleanly', () {
      // Reachable in principle: a route file's path segment is a filename,
      // and the filesystem does not reject these characters (only `/` and
      // NUL are forbidden) even though a real route tree would not use them.
      final out = syncManifest(_imports, [
        file(
          importPath: r"routes/it's/$weird/back\slash.dart",
          prefix: r'$weird',
          template: [r"it's", r'$weird', r'back\slash'],
        ),
      ]);
      expect(
        out,
        contains(r"import 'routes/it\'s/\$weird/back\\slash.dart' as $weird;"),
      );
      expect(
        out,
        contains(
          r"$weird.exported.bind(app, const ['it\'s', '\$weird', 'back\\slash']);",
        ),
      );
    });

    test('hostile segments — quote, dollar, backslash, newline, tab — emit '
        'source that actually parses', () {
      // The `contains` assertions above pin the exact escaped text; they
      // cannot see whether the *rest* of the emitted file still parses. A
      // raw control character (legal in a POSIX filename) is the gap: it
      // would otherwise land in the generated source as a literal newline
      // or tab and split the line, producing an unterminated string
      // literal the emitter itself cannot detect. Feeding the generated
      // region through a real Dart parser is the only check that catches
      // that class of bug.
      final out = syncManifest(_imports, [
        file(
          importPath: "routes/it's/\$weird/back\\slash/new\nline/ta\tb.dart",
          prefix: r'$hostile',
          template: [
            "it's",
            r'$weird',
            r'back\slash',
            'new\nline',
            'ta\tb',
            'cr\rreturn',
          ],
        ),
      ]);
      expect(() => parseString(content: out), returnsNormally);
    });

    test('every region is fenced from the formatter', () {
      // Without the fence the manifest never settles: a binding wider than 80
      // columns is reflowed by `dart format`, the next sync writes it back, and
      // "syncing is a no-op" — the one assertion between the tree and the
      // routes — cannot hold. Asserted here rather than left to the day someone
      // tidies the fence away.
      final out = syncManifest(_imports, [
        file(
          importPath: 'routes/users/_uid/tags/_index.dart',
          prefix: r'$users_uid_tags_index',
          template: ['users', ':uid', 'tags', ':index'],
        ),
      ]);
      expect('// dart format off'.allMatches(out).length, 2);
      expect('// dart format on'.allMatches(out).length, 2);

      // The binding this exists for: 85 columns, on one line, inside a fence.
      final binding = out
          .split('\n')
          .firstWhere((l) => l.contains('.exported.bind('));
      expect(binding.length, greaterThan(80));
      final lines = out.split('\n');
      final at = lines.indexOf(binding);
      expect(
        lines.sublist(0, at).lastWhere((l) => l.trim().startsWith('// dart')),
        contains('off'),
      );
    });
  });

  group('a scope rides along on the routes it wraps', () {
    const root = MiddlewareFile(
      importPath: 'routes/_middleware.dart',
      prefix: r'$mw$root',
      dir: [],
      scope: [],
    );
    const admin = MiddlewareFile(
      importPath: 'routes/admin/_middleware.dart',
      prefix: r'$mw$admin',
      dir: ['admin'],
      scope: ['admin'],
    );

    test(
      'a route under scopes binds them as an outer→inner third argument',
      () {
        final out = syncManifest(_imports, const [
          RouteFile(
            importPath: 'routes/admin/ping.dart',
            prefix: r'$admin_ping',
            template: ['admin', 'ping'],
            middleware: [root, admin],
          ),
        ]);
        expect(
          out,
          contains(
            r"$admin_ping.exported.bind(app, const ['admin', 'ping'], "
            r'[$mw$root.scoped, $mw$admin.scoped]);',
          ),
        );
      },
    );

    test('the imports region carries the scopes the routes reference', () {
      final out = syncManifest(_imports, const [
        RouteFile(
          importPath: 'routes/admin/ping.dart',
          prefix: r'$admin_ping',
          template: ['admin', 'ping'],
          middleware: [root, admin],
        ),
      ]);
      expect(out, contains(r"import 'routes/_middleware.dart' as $mw$root;"));
      expect(
        out,
        contains(r"import 'routes/admin/_middleware.dart' as $mw$admin;"),
      );
    });

    test('a middleware import line silences the same two infos', () {
      // The double-`$` middleware alias is the one `library_prefixes`
      // actually flags (a single leading `$` alone passes its check); the
      // generator does not special-case that away, since routing on which
      // diagnostic a given alias shape happens to trigger today is exactly
      // the kind of fragile knowledge this suppression exists to not need.
      final out = syncManifest(_imports, const [
        RouteFile(
          importPath: 'routes/admin/ping.dart',
          prefix: r'$admin_ping',
          template: ['admin', 'ping'],
          middleware: [root, admin],
        ),
      ]);
      expect(
        out,
        contains(
          "import 'routes/admin/_middleware.dart' as \$mw\$admin; "
          '// ignore: directives_ordering, library_prefixes',
        ),
      );
    });

    test('a scope shared by two routes is imported once', () {
      final out = syncManifest(_imports, const [
        RouteFile(
          importPath: 'routes/admin/ping.dart',
          prefix: r'$admin_ping',
          template: ['admin', 'ping'],
          middleware: [root, admin],
        ),
        RouteFile(
          importPath: 'routes/admin/stats.dart',
          prefix: r'$admin_stats',
          template: ['admin', 'stats'],
          middleware: [root, admin],
        ),
      ]);
      expect(
        r"import 'routes/admin/_middleware.dart' as $mw$admin;"
            .allMatches(out)
            .length,
        1,
      );
    });

    test('a route under no scope keeps the plain two-argument form', () {
      // The feature does not churn a manifest with no middleware in it: the
      // binding is byte-for-byte what it was before scopes existed.
      final out = syncManifest(_imports, [
        file(importPath: 'routes/x.dart', prefix: r'$x', template: ['x']),
      ]);
      expect(out, contains(r"$x.exported.bind(app, const ['x']);"));
    });

    test('a manifest with scopes is idempotent, and drift-free', () {
      const f = RouteFile(
        importPath: 'routes/admin/ping.dart',
        prefix: r'$admin_ping',
        template: ['admin', 'ping'],
        middleware: [root, admin],
      );
      final synced = syncManifest(_imports, [f]);
      expect(syncManifest(synced, [f]), synced, reason: 'settled');
      expect(unregistered(synced, [f]), isEmpty);
    });

    test('a drifted scope chain leaves the route reported as unregistered', () {
      // The third argument is part of the binding line, so a manifest synced
      // when the route had no scope no longer matches once a scope appears.
      final withoutScope = syncManifest(_imports, const [
        RouteFile(
          importPath: 'routes/admin/ping.dart',
          prefix: r'$admin_ping',
          template: ['admin', 'ping'],
        ),
      ]);
      const withScope = RouteFile(
        importPath: 'routes/admin/ping.dart',
        prefix: r'$admin_ping',
        template: ['admin', 'ping'],
        middleware: [root, admin],
      );
      expect(unregistered(withoutScope, [withScope]), [withScope]);
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

  group('a CRLF manifest keeps its own convention, not a mix', () {
    // The fixtures above are LF; this mirrors them character-for-character
    // but with '\r\n' line endings, the way a Windows checkout or a
    // Windows-authored file would actually look on disk.
    final importsCrlf = _imports.replaceAll('\n', '\r\n');
    final f = file(importPath: 'routes/x.dart', prefix: r'$x', template: ['x']);

    test('sync of a CRLF manifest emits uniform CRLF', () {
      final out = syncManifest(importsCrlf, [f]);
      expect(out, contains('\r\n'));
      // Stripping every '\r\n' pair must remove every newline in the
      // result. A bare '\n' surviving that means some line — preserved or
      // generated — did not get the '\r', i.e. exactly the mixed-EOL bug
      // this guards against.
      expect(out.replaceAll('\r\n', ''), isNot(contains('\n')));
    });

    test('sync of a CRLF manifest is idempotent', () {
      final synced = syncManifest(importsCrlf, [f]);
      expect(syncManifest(synced, [f]), synced, reason: 'settled');
    });

    test('marker detection still works on a CRLF manifest', () {
      final synced = syncManifest(importsCrlf, [f]);
      expect(unregistered(synced, [f]), isEmpty);
      expect(unregistered(importsCrlf, [f]), [f]);
    });

    test('a plain LF manifest is untouched by the CRLF handling', () {
      final out = syncManifest(_imports, [f]);
      expect(out, isNot(contains('\r')));
    });
  });

  group('drift is caught', () {
    final f = file(importPath: 'routes/x.dart', prefix: r'$x', template: ['x']);

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
