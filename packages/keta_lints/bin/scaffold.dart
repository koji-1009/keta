import 'dart:io';

import 'package:keta_lints/keta_lints.dart';
import 'package:path/path.dart' as p;

/// Materializes user-owned Dart from an OpenAPI contract — DTOs, mappers,
/// schema constants, route skeletons, tool/openapi.dart, and DTO contract
/// tests. Existing files are not overwritten.
///
///   dart run keta_lints:scaffold openapi.yaml [outDir]
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: scaffold <openapi.yaml> [outDir]');
    exit(64);
  }
  final specFile = File(args[0]);
  if (!specFile.existsSync()) {
    stderr.writeln('no such file: ${args[0]}');
    exit(66);
  }
  final outDir = args.length > 1 ? args[1] : '.';

  final Scaffold scaffold;
  try {
    scaffold = generateScaffold(loadYamlDocument(specFile.readAsStringSync()));
  } on ScaffoldError catch (e) {
    stderr.writeln(e.message);
    exit(65);
  }

  final files = {
    p.join(outDir, 'lib', 'dtos.dart'): scaffold.dtos,
    p.join(outDir, 'lib', 'routes.dart'): scaffold.routes,
    p.join(outDir, 'tool', 'openapi.dart'): scaffold.openapiTool,
    p.join(outDir, 'test', 'dto_contract_test.dart'): scaffold.contractTest,
  };
  for (final entry in files.entries) {
    final file = File(entry.key);
    if (file.existsSync()) {
      stdout.writeln('skip (exists): ${entry.key}');
      continue;
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
    stdout.writeln('wrote ${entry.key}');
  }
}
