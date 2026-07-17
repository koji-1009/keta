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
  final found = discover(routesDir);
  manifest.writeAsStringSync(
    syncManifest(manifest.readAsStringSync(), found.routes),
  );
  // Middleware is counted by what a route falls under, not by how many files
  // exist: a `_middleware.dart` scoping nothing is imported nowhere, and is the
  // check's job to name — sync only wires what runs.
  final scopes = {
    for (final r in found.routes)
      for (final m in r.middleware) m.importPath,
  }.length;
  stdout.writeln(
    'synced ${found.routes.length} route file(s)'
    '${scopes == 0 ? '' : ' under $scopes middleware scope(s)'} into $manifestPath',
  );
}
