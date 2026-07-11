import 'dart:io';

import 'package:keta_files/keta_files.dart';

/// Reports route files under the routes directory that are not yet registered
/// in the manifest. Exits non-zero when any are missing, so it gates CI.
///
///   dart run keta_files:check [routesDir] [manifest]
void main(List<String> args) {
  final routesDir = args.isNotEmpty ? args[0] : 'lib/routes';
  final manifestPath = args.length > 1 ? args[1] : 'lib/routes.dart';

  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    stderr.writeln('no manifest at $manifestPath');
    exit(66);
  }
  final missing =
      unregistered(manifest.readAsStringSync(), discoverRouteFiles(routesDir));
  if (missing.isEmpty) {
    stdout.writeln('all route files are registered');
    return;
  }
  for (final file in missing) {
    stdout.writeln('unregistered: ${file.importPath} '
        '(run keta_files:sync to add ${file.prefix}.register(app))');
  }
  exit(1);
}
