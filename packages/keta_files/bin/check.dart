import 'dart:io';

import 'package:keta_files/keta_files.dart';

/// Reports route files whose URL the manifest does not serve. Exits non-zero
/// when any are, so it gates CI.
///
///   dart run keta_files:check [routesDir] [manifest]
///
/// The failure it exists for is silent: a file sits under routes/ looking like
/// a route, compiles, passes the suite — and its URL 404s, because nothing
/// bound it.
void main(List<String> args) {
  final routesDir = args.isNotEmpty ? args[0] : 'lib/routes';
  final manifestPath = args.length > 1 ? args[1] : 'lib/routes.dart';

  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    stderr.writeln('no manifest at $manifestPath');
    exit(66);
  }
  final missing = unregistered(
    manifest.readAsStringSync(),
    discoverRouteFiles(routesDir),
  );
  if (missing.isEmpty) {
    stdout.writeln('every route file is served at the URL it denotes');
    return;
  }
  for (final file in missing) {
    stdout.writeln('not served: ${file.url}  (${file.importPath})');
  }
  stdout.writeln('run `dart run keta_files:sync` to bind them');
  exit(1);
}
