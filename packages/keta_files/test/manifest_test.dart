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
    expect(() => syncManifest('void main() {}', const []),
        throwsA(isA<FormatException>()));
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
}
