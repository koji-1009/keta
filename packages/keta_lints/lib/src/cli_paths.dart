library;

import 'dart:io';

/// Resolves the CLI's file arguments to the `.dart` files to analyze, refusing
/// anything that would let a gate report success without having looked.
///
/// Both CLI entry points (`check`, `fix`) are run as CI gates, and the failure
/// that matters for a gate is not "it found a problem" — it is "it found
/// nothing, said so, and exited 0". Three ways in used to reach that:
///
/// * a path that does not exist was skipped in silence, so a typo'd or moved
///   directory in a workflow printed `no issues` and passed forever;
/// * a named file that does not exist was passed through to be read, which
///   threw an unhandled `FileSystemException` — noisy, but as a *crash* rather
///   than a diagnostic exit code;
/// * arguments that resolved to zero `.dart` files were indistinguishable from
///   arguments that resolved to clean ones.
///
/// All three are usage errors, and all three now exit 64 (`EX_USAGE`) with a
/// message naming the path. Shared rather than copied because it was copied,
/// and the copies had already drifted apart.
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
