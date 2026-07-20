import 'dart:io';

import 'package:keta_lints/keta_lints.dart';

/// Project-wide checks. Exits non-zero on any finding, so it gates CI.
///
/// ```
/// dart run keta_lints:check drift <oracle.yaml> <shadow.yaml>
/// dart run keta_lints:check canonical <file-or-dir> ...
/// dart run keta_lints:check routes <file-or-dir> ...
/// dart run keta_lints:check query <file-or-dir> ...
/// dart run keta_lints:check internal-await <file-or-dir> ...
/// dart run keta_lints:check key <file-or-dir> ...
/// dart run keta_lints:check tx <file-or-dir> ...
/// ```
///
/// `drift` is the contract-drift document diff between the externally-supplied
/// contract (oracle) and the OpenAPI the code emits. `canonical` reports DTOs
/// whose mappers are missing or drifted. `routes` reports unknown params and
/// unused captures. `internal-await` guards the framework's synchronous path.
/// `key` reports a Context key constructed inline at a get/tryGet/set call.
/// `tx` reports `use(tx())` registered outside `use(recover())`. `order`
/// reports any other `use()` run whose middleware positions descend.
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: check '
      '<drift|canonical|routes|query|internal-await|key|tx|order> ...',
    );
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
    case 'query':
      _sourceCheck(args.sublist(1), queryDiagnostics, 'no query issues');
    case 'internal-await':
      _sourceCheck(
        args.sublist(1),
        internalAwaitDiagnostics,
        'no internal awaits',
      );
    case 'key':
      _sourceCheck(args.sublist(1), keyDiagnostics, 'no inline keys');
    case 'tx':
      _sourceCheck(args.sublist(1), txOrderDiagnostics, 'no tx-order issues');
    case 'order':
      _sourceCheck(
        args.sublist(1),
        middlewareOrderDiagnostics,
        'no middleware-order issues',
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
  // Key the id on the package-relative path so a drift finding correlates
  // across machines and with the IDE, not on the absolute/typed oracle path.
  _report(
    contractDrift(oracle, shadow, file: packageRelativePath(args[0])),
    'no contract drift',
  );
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
      // Normalize to a package-relative path so the stable id matches the one
      // the analyzer plugin computes from its absolute path, and matches across
      // machines regardless of how the file was addressed on the command line.
      ...analyze(
        File(file).readAsStringSync(),
        file: packageRelativePath(file),
      ),
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
