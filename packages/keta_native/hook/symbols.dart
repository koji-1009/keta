/// Derives the link hook's tree-shake keep-list from the `@Native` bindings
/// themselves — there is no hand-maintained list; `lib/src/ffi/libcrypto.dart`
/// is the single source.
///
/// Each binding must carry `@RecordUse()`, `@Native` with an explicit
/// `symbol:`, and its `external` declaration. A binding missing any of the
/// three would either ship an AOT library without its symbol (implicit
/// Dart-name default, invisible to this parse) or be silently dropped by a
/// record-use build (never recorded, so treated as unused), so both cases
/// fail the build here instead of failing at load time in a deployed binary.
library;

import 'dart:io';

/// The bindings file the keep-list is derived from, relative to the package
/// root.
const bindingsPath = 'lib/src/ffi/libcrypto.dart';

/// A parsed `@Native` binding: the Dart declaration name (what record-use
/// identifies) and the C symbol (what the linker keeps).
typedef Binding = ({String dartName, String symbol});

/// Parses the `@Native` bindings under [packageRoot].
List<Binding> readBindings(Uri packageRoot) {
  final bindings = File.fromUri(packageRoot.resolve(bindingsPath));
  final source = bindings.readAsStringSync();
  final symbols = RegExp(
    r"symbol: '([A-Za-z0-9_]+)'",
  ).allMatches(source).map((match) => match.group(1)!).toList();
  final dartNames = RegExp(
    r'^external\s[^(]*?(\w+)\(',
    multiLine: true,
  ).allMatches(source).map((match) => match.group(1)!).toList();
  // Anchored to line starts: both annotation names also occur in prose
  // inside doc comments, which must not count.
  final natives = RegExp(
    r'^@Native<',
    multiLine: true,
  ).allMatches(source).length;
  final recordUses = RegExp(
    r'^@RecordUse\(\)$',
    multiLine: true,
  ).allMatches(source).length;
  if (symbols.isEmpty ||
      symbols.length != natives ||
      dartNames.length != natives ||
      recordUses != natives) {
    throw StateError(
      '${bindings.path}: $natives @Native bindings, $recordUses @RecordUse() '
      'annotations, ${symbols.length} explicit symbol: entries, '
      '${dartNames.length} external declarations — every binding must carry '
      'all three so the keep-list derived here is exhaustive and record-use '
      'builds see every call.',
    );
  }
  return [
    for (var i = 0; i < natives; i++)
      (dartName: dartNames[i], symbol: symbols[i]),
  ];
}
