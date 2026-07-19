// End-to-end tests for the three `bin/` CLIs (check / fix / scaffold), driven
// as real subprocesses against the SDK binary over a temp-dir fixture project.
// These exercise the parts the in-process unit tests cannot: exit codes (the CI
// contract), directory walking, in-place rewrites, and scaffold's
// skip-existing behavior — none of which had coverage before.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The Dart VM running this test — the CLIs run under the *same* SDK, whatever
/// it is, so the suite is portable to any CI checkout (no hardcoded SDK path).
/// [Platform.resolvedExecutable] is the `dart` binary itself, which takes a
/// script path (`dart bin/check.dart …`) exactly as a pinned SDK binary would.
final _dart = Platform.resolvedExecutable;

/// `bin/<name>` resolved against the package root (the cwd under `dart test`).
String _script(String name) => p.join(Directory.current.path, 'bin', name);

ProcessResult _run(String script, List<String> args) =>
    Process.runSync(_dart, [script, ...args]);

/// The 16-hex stable id from a `[<id>] …` diagnostic line, or null.
String? _idOf(String output) =>
    RegExp(r'\[([0-9a-f]{16})\]').firstMatch(output)?.group(1);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('keta_lints_cli'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(String name, String content) {
    final file = File(p.join(dir.path, name))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
    return file.path;
  }

  group('check', () {
    const clean = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';
    const drifted = '''
class Dto {
  final String id;
  final String name;
  Dto({required this.id, required this.name});
  factory Dto.fromJson(Map<String, Object?> json) =>
      Dto(id: json['id'] as String, name: json['name'] as String);
  Map<String, Object?> toJson() => {'id': id};
}
''';

    test('exits 0 on a clean file', () {
      final r = _run(_script('check.dart'), [
        'canonical',
        write('clean.dart', clean),
      ]);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('no canonical issues'));
    });

    test('exits 1 on a drifted file', () {
      final r = _run(_script('check.dart'), [
        'canonical',
        write('bad.dart', drifted),
      ]);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('keta_canonical_drift'));
    });

    test('walks a directory and flags a drift found in it', () {
      write('sub/clean.dart', clean);
      write('sub/bad.dart', drifted);
      final r = _run(_script('check.dart'), [
        'canonical',
        p.join(dir.path, 'sub'),
      ]);
      expect(r.exitCode, 1);
      expect(r.stderr, contains('finding(s)'));
    });

    test('exits 64 on a usage error (no subcommand)', () {
      final r = _run(_script('check.dart'), const []);
      expect(r.exitCode, 64);
    });

    test('tx: exits 0 when recover() is registered before tx()', () {
      final r = _run(_script('check.dart'), [
        'tx',
        write(
          'ok.dart',
          'void register(app) { app..use(recover())..use(tx()); }',
        ),
      ]);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('no tx-order issues'));
    });

    test('tx: exits 1 when tx() is registered outside recover()', () {
      final r = _run(_script('check.dart'), [
        'tx',
        write(
          'bad.dart',
          'void register(app) { app..use(tx())..use(recover()); }',
        ),
      ]);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('keta_tx_outside_recover'));
    });

    test(
      'a finding carries the same stable id whether the file is addressed '
      'absolutely (as the analyzer plugin supplies it) or relatively (as a '
      'user invokes the CLI) — the item-1 portability guarantee, end to end',
      () {
        File(
          p.join(dir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: fixture\n');
        const rel = 'lib/foo.dart';
        write(rel, '''
class Point {
  final int x;
  Point(this.x);
  Map<String, Object?> toJson() => {'x': x};
}
''');
        final abs = p.join(dir.path, rel);
        // Run the CLI from INSIDE the fixture package both ways. The child
        // process's own cwd resolves the relative path; the test process's cwd is
        // never touched.
        final relRun = Process.runSync(_dart, [
          _script('check.dart'),
          'canonical',
          rel,
        ], workingDirectory: dir.path);
        final absRun = Process.runSync(_dart, [
          _script('check.dart'),
          'canonical',
          abs,
        ], workingDirectory: dir.path);
        expect(relRun.exitCode, 1);
        expect(absRun.exitCode, 1);
        final relId = _idOf(relRun.stdout as String);
        final absId = _idOf(absRun.stdout as String);
        expect(relId, isNotNull);
        expect(relId, absId);
      },
    );
  });

  group('fix', () {
    const missingToJson = '''
class Dto {
  final String id;
  Dto({required this.id});
  factory Dto.fromJson(Map<String, Object?> json) => Dto(id: json['id'] as String);
}
''';

    test('rewrites a file in place, then is a no-op on a second run', () {
      final path = write('dto.dart', missingToJson);
      final first = _run(_script('fix.dart'), ['canonical', path]);
      expect(first.exitCode, 0);
      expect(first.stdout, contains('fixed'));
      expect(
        File(path).readAsStringSync(),
        contains('Map<String, Object?> toJson()'),
      );

      final second = _run(_script('fix.dart'), ['canonical', path]);
      expect(second.exitCode, 0);
      expect(second.stdout, contains('nothing to fix'));
    });

    test('exits 64 on a usage error', () {
      final r = _run(_script('fix.dart'), const []);
      expect(r.exitCode, 64);
    });
  });

  group('scaffold', () {
    const spec = '''
openapi: '3.1.0'
info:
  title: t
  version: '1'
paths: {}
components:
  schemas:
    UserDto:
      type: object
      required:
        - id
      properties:
        id:
          type: string
''';

    test('writes the four files, then skips the existing ones on a re-run', () {
      final specPath = write('openapi.yaml', spec);
      final out = p.join(dir.path, 'out');
      final first = _run(_script('scaffold.dart'), [specPath, out]);
      expect(first.exitCode, 0);
      expect(first.stdout, contains('wrote'));
      expect(File(p.join(out, 'lib', 'dtos.dart')).existsSync(), isTrue);
      expect(
        File(p.join(out, 'test', 'dto_contract_test.dart')).existsSync(),
        isTrue,
      );

      final second = _run(_script('scaffold.dart'), [specPath, out]);
      expect(second.exitCode, 0);
      expect(second.stdout, contains('skip (exists)'));
    });

    test('exits 64 with no args', () {
      expect(_run(_script('scaffold.dart'), const []).exitCode, 64);
    });

    test('exits 66 when the spec file is missing', () {
      final r = _run(_script('scaffold.dart'), [p.join(dir.path, 'nope.yaml')]);
      expect(r.exitCode, 66);
    });

    test('exits 65 on an out-of-canonical construct (ScaffoldError)', () {
      const bad = '''
openapi: '3.1.0'
info:
  title: t
  version: '1'
components:
  schemas:
    Bad:
      type: object
      required:
        - x
      properties:
        x:
          type: object
          additionalProperties: true
''';
      final r = _run(_script('scaffold.dart'), [write('bad.yaml', bad)]);
      expect(r.exitCode, 65);
    });
  });
}
