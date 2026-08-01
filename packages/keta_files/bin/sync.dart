import 'dart:io';

import 'package:keta_files/keta_files.dart';

/// Materializes route registrations into a manifest's marked regions.
///
///   dart run keta_files:sync [--check] [routesDir] [manifest]
///
/// Defaults: routesDir `lib/routes`, manifest `lib/routes.dart`. The manifest
/// must already contain the `// keta_files:imports` / `// keta_files:routes`
/// markers, each closed by `// keta_files:end`.
///
/// `--check` writes nothing and exits 1 when a sync would change the file —
/// the verify mode of the writer, in the shape `dart format
/// --set-exit-if-changed` uses. It is the stronger of the two gates this
/// package offers: `keta_files:check` asks whether every route file is bound,
/// which cannot see a binding no file denotes, a region out of order, or a lost
/// format fence. This asks whether the file already IS what the generator would
/// write, which is the invariant the design actually rests on.
void main(List<String> args) {
  final check = args.contains('--check');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final routesDir = positional.isNotEmpty ? positional[0] : 'lib/routes';
  final manifestPath = positional.length > 1
      ? positional[1]
      : 'lib/routes.dart';

  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    stderr.writeln('no manifest at $manifestPath (create it with the markers)');
    exit(66);
  }
  final found = discover(routesDir);
  final source = manifest.readAsStringSync();

  if (check) {
    if (manifestIsSynced(source, found.routes)) {
      stdout.writeln('$manifestPath is in sync with $routesDir');
      return;
    }
    // Name what is wrong where it can be named. `unregistered` answers the
    // common case — a file nobody bound — precisely; the rest (a stale binding,
    // reordering, a lost fence) has no per-file name, so it is reported as what
    // it is rather than guessed at.
    final missing = unregistered(source, found.routes);
    for (final file in missing) {
      stdout.writeln('not served: ${file.url}  (${file.importPath})');
    }
    if (missing.isEmpty) {
      stdout.writeln(
        'the managed regions differ from what the tree denotes '
        '(a stale binding, a reordering, or a lost `dart format off` fence)',
      );
    }
    stdout.writeln('run `dart run keta_files:sync` to bring it back');
    exit(1);
  }

  manifest.writeAsStringSync(syncManifest(source, found.routes));
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
