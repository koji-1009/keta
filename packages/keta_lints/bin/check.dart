import 'dart:io';

import 'package:keta_lints/keta_lints.dart';

/// Project-wide checks. Currently the contract-drift document diff: it compares
/// the externally-supplied contract (oracle) with the OpenAPI the code emits
/// (shadow, produced by `dart run tool/openapi.dart > shadow.yaml`).
///
///   dart run keta_lints:check <oracle.yaml> <shadow.yaml>
///
/// Exit code is non-zero when any drift is found, so it gates CI.
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: check <oracle.yaml> <shadow.yaml>');
    exit(64);
  }
  final oracle = loadYamlDocument(File(args[0]).readAsStringSync());
  final shadow = loadYamlDocument(File(args[1]).readAsStringSync());

  final diagnostics = contractDrift(oracle, shadow, file: args[0]);
  if (diagnostics.isEmpty) {
    stdout.writeln('no contract drift');
    return;
  }
  for (final d in diagnostics) {
    stdout.writeln(d);
  }
  stderr.writeln('${diagnostics.length} drift finding(s)');
  exit(1);
}
