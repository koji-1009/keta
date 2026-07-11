import 'dart:io';

import 'package:keta_files/keta_files.dart';

/// Materializes route registrations into a manifest's marked regions.
///
///   dart run keta_files:sync [routesDir] [manifest]
///
/// Defaults: routesDir `lib/routes`, manifest `lib/routes.dart`. The manifest
/// must already contain the `// keta_files:imports` / `// keta_files:routes`
/// markers, each closed by `// keta_files:end`.
void main(List<String> args) {
  final routesDir = args.isNotEmpty ? args[0] : 'lib/routes';
  final manifestPath = args.length > 1 ? args[1] : 'lib/routes.dart';

  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    stderr.writeln('no manifest at $manifestPath (create it with the markers)');
    exit(66);
  }
  final files = discoverRouteFiles(routesDir);
  manifest.writeAsStringSync(syncManifest(manifest.readAsStringSync(), files));
  stdout.writeln('synced ${files.length} route file(s) into $manifestPath');
}
