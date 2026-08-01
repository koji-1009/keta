import 'dart:io';

import 'package:keta_files/keta_files.dart';

/// Reports route files whose URL the manifest does not serve, and middleware
/// that scopes none. Exits non-zero when any are, so it gates CI.
///
///   dart run keta_files:check [routesDir] [manifest]
///
/// The failure it exists for is silent: a file sits under routes/ looking like
/// a route, compiles, passes the suite — and its URL 404s, because nothing
/// bound it.
///
/// This asks a narrower question than `keta_files:sync --check`, which compares
/// the file against what the generator would write. Both are checked here, so
/// the two cannot disagree: drift the per-file diagnostics cannot name — a
/// binding no file denotes, a region out of order, a lost `dart format off`
/// fence — still fails, reported as what it is.
void main(List<String> args) {
  final routesDir = args.isNotEmpty ? args[0] : 'lib/routes';
  final manifestPath = args.length > 1 ? args[1] : 'lib/routes.dart';

  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    stderr.writeln('no manifest at $manifestPath');
    exit(66);
  }
  final found = discover(routesDir);
  final source = manifest.readAsStringSync();
  final missing = unregistered(source, found.routes);
  // A middleware file scoping no route is a scope silently guarding nothing —
  // the same class of quiet failure this check exists for, so it fails CI on its
  // own condition rather than being tolerated into meaninglessness.
  final orphans = orphanMiddleware(found.routes, found.middleware);
  // The regions may also disagree in ways no route file can be blamed for.
  // Asking the generator settles those, and costs nothing here.
  final synced = manifestIsSynced(source, found.routes);

  if (missing.isEmpty && orphans.isEmpty && synced) {
    stdout.writeln('every route file is served at the URL it denotes');
    return;
  }
  for (final file in missing) {
    stdout.writeln('not served: ${file.url}  (${file.importPath})');
  }
  for (final m in orphans) {
    stdout.writeln('scopes no route: ${m.url}  (${m.importPath})');
  }
  if (!synced && missing.isEmpty) {
    stdout.writeln(
      'the managed regions differ from what the tree denotes '
      '(a stale binding, a reordering, or a lost `dart format off` fence)',
    );
  }
  if (missing.isNotEmpty || !synced) {
    stdout.writeln('run `dart run keta_files:sync` to bring it back');
  }
  exit(1);
}
