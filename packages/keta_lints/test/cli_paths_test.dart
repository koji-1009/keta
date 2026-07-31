/// Owns the CLI's file resolution — the part that decides whether a gate is
/// allowed to say "clean".
///
/// Both entry points run as CI gates, so the failure that matters is not
/// "found a problem" but "found nothing, said so, and exited 0". A path that
/// did not exist used to be skipped in silence, which made a typo'd or moved
/// directory in a workflow print `no issues` and pass forever.
@TestOn('vm')
library;

import 'dart:io';

import 'package:keta_lints/keta_lints.dart';
import 'package:test/test.dart';

/// Runs the CLI in a child process, because a usage error is an `exit(64)` —
/// which cannot be observed in-process without taking the test runner with it.
({int code, String stderr}) runCheck(List<String> args) {
  final r = Process.runSync(Platform.resolvedExecutable, [
    'run',
    'keta_lints:check',
    ...args,
  ], workingDirectory: Directory.current.path);
  return (code: r.exitCode, stderr: '${r.stderr}');
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('keta_lints_cli'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('a gate must not report success without having looked', () {
    test('a directory that does not exist is a usage error', () {
      final r = runCheck(['routes', '${tmp.path}/does-not-exist']);
      expect(r.code, 64);
      expect(r.stderr, contains('no such file or directory'));
    });

    test('a named Dart file that does not exist is a usage error', () {
      // Previously reached `readAsStringSync` and crashed with an unhandled
      // FileSystemException — noisy, but as a crash rather than a diagnostic
      // exit code.
      final r = runCheck(['routes', '${tmp.path}/gone.dart']);
      expect(r.code, 64);
      expect(r.stderr, contains('no such file or directory'));
    });

    test('arguments that resolve to zero Dart files are a usage error', () {
      File('${tmp.path}/README.md').writeAsStringSync('not dart');
      final r = runCheck(['routes', tmp.path]);
      expect(r.code, 64);
      expect(r.stderr, contains('refusing to report success'));
    });

    test('a file that is not Dart, named explicitly, is a usage error', () {
      final notDart = '${tmp.path}/config.yaml';
      File(notDart).writeAsStringSync('a: 1');
      final r = runCheck(['routes', notDart]);
      expect(r.code, 64);
      expect(r.stderr, contains('not a Dart file'));
    });

    test('a real directory with Dart in it still checks and passes', () {
      File('${tmp.path}/clean.dart').writeAsStringSync('void main() {}\n');
      final r = runCheck(['routes', tmp.path]);
      expect(r.code, 0);
    });
  });

  group('resolveDartFiles', () {
    test('walks a directory recursively and returns a stable order', () {
      Directory('${tmp.path}/nested').createSync();
      File('${tmp.path}/b.dart').writeAsStringSync('');
      File('${tmp.path}/a.dart').writeAsStringSync('');
      File('${tmp.path}/nested/c.dart').writeAsStringSync('');
      File('${tmp.path}/skip.txt').writeAsStringSync('');

      final files = resolveDartFiles([tmp.path]);
      expect(files, hasLength(3));
      expect(files, equals([...files]..sort()));
      expect(files.every((f) => f.endsWith('.dart')), isTrue);
    });

    test('accepts an explicitly named Dart file', () {
      final path = '${tmp.path}/one.dart';
      File(path).writeAsStringSync('');
      expect(resolveDartFiles([path]), [path]);
    });
  });
}
