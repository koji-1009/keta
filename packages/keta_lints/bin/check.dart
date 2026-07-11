import 'dart:io';

import 'package:keta_lints/keta_lints.dart';

/// Project-wide checks. Exits non-zero on any finding, so it gates CI.
///
///   dart run keta_lints:check drift <oracle.yaml> <shadow.yaml>
///   dart run keta_lints:check canonical <file-or-dir> ...
///
/// `drift` is the contract-drift document diff between the externally-supplied
/// contract (oracle) and the OpenAPI the code emits (shadow, from
/// `dart run tool/openapi.dart`). `canonical` reports DTOs whose mappers are
/// missing or drifted.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: check <drift|canonical> ...');
    exit(64);
  }
  switch (args.first) {
    case 'drift':
      _drift(args.sublist(1));
    case 'canonical':
      _canonical(args.sublist(1));
    default:
      stderr.writeln('unknown check "${args.first}" (expected drift|canonical)');
      exit(64);
  }
}

void _drift(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: check drift <oracle.yaml> <shadow.yaml>');
    exit(64);
  }
  final oracle = loadYamlDocument(File(args[0]).readAsStringSync());
  final shadow = loadYamlDocument(File(args[1]).readAsStringSync());
  _report(contractDrift(oracle, shadow, file: args[0]), 'no contract drift');
}

void _canonical(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: check canonical <file-or-dir> ...');
    exit(64);
  }
  final diagnostics = [
    for (final file in _dartFiles(args))
      ...canonicalDiagnostics(File(file).readAsStringSync(), file: file),
  ];
  _report(diagnostics, 'no canonical issues');
}

Iterable<String> _dartFiles(List<String> paths) sync* {
  for (final path in paths) {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      yield* Directory(path)
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.endsWith('.dart'));
    } else if (path.endsWith('.dart')) {
      yield path;
    }
  }
}

void _report(List<Diagnostic> diagnostics, String cleanMessage) {
  if (diagnostics.isEmpty) {
    stdout.writeln(cleanMessage);
    return;
  }
  for (final d in diagnostics) {
    stdout.writeln(d);
  }
  stderr.writeln('${diagnostics.length} finding(s)');
  exit(1);
}
