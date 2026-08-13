library;

import 'dart:io';

/// Resolves the CLI's file arguments to the `.dart` files to analyze, refusing
/// anything that would let a gate report success without having looked.
///
/// Both CLI entry points (`check`, `fix`) are run as CI gates, and the failure
/// that matters for a gate is not "it found a problem" — it is "it found
/// nothing, said so, and exited 0". Three inputs would otherwise reach that:
///
/// * a path that does not exist — a typo'd or moved directory in a workflow
///   would print `no issues` and pass forever;
/// * a named file that does not exist — read straight through, it throws an
///   unhandled `FileSystemException`, a crash rather than a diagnostic exit;
/// * arguments that resolve to zero `.dart` files, indistinguishable from
///   arguments that resolve to clean ones.
///
/// All three are usage errors and all three exit 64 (`EX_USAGE`) with a message
/// naming the path. Shared by both entry points so the two cannot drift.
List<String> resolveDartFiles(List<String> paths) {
  final files = <String>[];
  for (final path in paths) {
    switch (FileSystemEntity.typeSync(path)) {
      case FileSystemEntityType.directory:
        files.addAll(
          Directory(path)
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => p.endsWith('.dart')),
        );
      case FileSystemEntityType.file:
        if (!path.endsWith('.dart')) {
          _usage('not a Dart file: $path');
        }
        files.add(path);
      default:
        _usage('no such file or directory: $path');
    }
  }
  if (files.isEmpty) {
    _usage(
      'no .dart files under: ${paths.join(', ')}\n'
      'refusing to report success without having examined anything',
    );
  }
  files.sort(); // Deterministic order, so output is diffable run to run.
  return files;
}

Never _usage(String message) {
  stderr.writeln(message);
  exit(64);
}
