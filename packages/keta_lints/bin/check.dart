import 'dart:io';

import 'package:keta_lints/keta_lints.dart';

/// Project-wide checks. Exits non-zero on any finding, so it gates CI.
///
/// ```
/// dart run keta_lints:check drift <oracle.yaml> <shadow.yaml>
/// dart run keta_lints:check canonical <file-or-dir> ...
/// dart run keta_lints:check routes <file-or-dir> ...
/// dart run keta_lints:check internal-await <file-or-dir> ...
/// ```
///
/// `drift` is the contract-drift document diff between the externally-supplied
/// contract (oracle) and the OpenAPI the code emits. `canonical` reports DTOs
/// whose mappers are missing or drifted. `routes` reports unknown params and
/// unused captures. `internal-await` guards the framework's synchronous path.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: check <drift|canonical|routes|internal-await> ...');
    exit(64);
  }
  switch (args.first) {
    case 'drift':
      _drift(args.sublist(1));
    case 'canonical':
      _sourceCheck(
        args.sublist(1),
        canonicalDiagnostics,
        'no canonical issues',
      );
    case 'routes':
      _sourceCheck(args.sublist(1), routeDiagnostics, 'no route issues');
    case 'internal-await':
      _sourceCheck(
        args.sublist(1),
        internalAwaitDiagnostics,
        'no internal awaits',
      );
    default:
      stderr.writeln('unknown check "${args.first}"');
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

void _sourceCheck(
  List<String> args,
  List<Diagnostic> Function(String source, {String file}) analyze,
  String cleanMessage,
) {
  if (args.isEmpty) {
    stderr.writeln('usage: check <kind> <file-or-dir> ...');
    exit(64);
  }
  final diagnostics = [
    for (final file in _dartFiles(args))
      ...analyze(File(file).readAsStringSync(), file: file),
  ];
  _report(diagnostics, cleanMessage);
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
