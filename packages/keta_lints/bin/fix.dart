import 'dart:io';

import 'package:keta_lints/keta_lints.dart';

/// Applies materializing repair fixes to source, in place.
///
///   dart run keta_lints:fix canonical <file-or-dir> ...
///
/// `canonical` materializes missing mappers, reconciles drifted ones, and
/// updates the matching Schema constant so OpenAPI reflects the change.
void main(List<String> args) {
  if (args.isEmpty || args.first != 'canonical' || args.length < 2) {
    stderr.writeln('usage: fix canonical <file-or-dir> ...');
    exit(64);
  }
  var changed = 0;
  for (final path in _dartFiles(args.sublist(1))) {
    final file = File(path);
    final source = file.readAsStringSync();
    final fixed = applyCanonicalFix(source);
    if (fixed != source) {
      file.writeAsStringSync(fixed);
      stdout.writeln('fixed $path');
      changed++;
    }
  }
  stdout.writeln(changed == 0 ? 'nothing to fix' : 'fixed $changed file(s)');
}

Iterable<String> _dartFiles(List<String> paths) sync* {
  for (final path in paths) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
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
