/// Derives the C symbols the link hook keeps when tree-shaking `libcrypto`
/// from the `@Native` bindings themselves — there is no hand-maintained
/// keep-list; `lib/src/ffi/libcrypto.dart` is the single source.
///
/// Every binding must carry an explicit `symbol:`. One relying on `@Native`'s
/// implicit Dart-name-as-symbol default would be invisible to this parse and
/// ship an AOT library missing its symbol, so that case fails the build here
/// instead of failing at load time in a deployed binary.
library;

import 'dart:io';

/// The bindings file the keep-list is derived from, relative to the package
/// root.
const bindingsPath = 'lib/src/ffi/libcrypto.dart';

/// Parses the `@Native` bindings under [packageRoot] into the tree-shake
/// keep-list.
List<String> readBoundSymbols(Uri packageRoot) {
  final bindings = File.fromUri(packageRoot.resolve(bindingsPath));
  final source = bindings.readAsStringSync();
  final symbols = RegExp(
    r"symbol: '([A-Za-z0-9_]+)'",
  ).allMatches(source).map((match) => match.group(1)!).toList();
  final annotations = '@Native<'.allMatches(source).length;
  if (symbols.length != annotations || symbols.isEmpty) {
    throw StateError(
      '${bindings.path}: $annotations @Native bindings but ${symbols.length} '
      'explicit symbol: entries — every binding must name its C symbol '
      'explicitly so the keep-list derived here is exhaustive.',
    );
  }
  return symbols;
}
