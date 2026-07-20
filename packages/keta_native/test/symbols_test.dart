import 'dart:io';

import 'package:test/test.dart';

import '../hook/symbols.dart';

void main() {
  group('hook/symbols.dart', () {
    // The keep-list drives the link hook's tree-shaking. A binding whose
    // symbol is missing from it still resolves in JIT runs (full library
    // bundled) but fails at load time in linked AOT builds — a gap this
    // suite cannot see at runtime, so it enforces the list statically.
    test(r'matches the @Native bindings in lib/src/ffi/libcrypto.dart', () {
      final source = File('lib/src/ffi/libcrypto.dart').readAsStringSync();
      final bound = RegExp(
        r"symbol: '([A-Za-z0-9_]+)'",
      ).allMatches(source).map((match) => match.group(1)!).toList();
      // A binding relying on @Native's implicit Dart-name-as-symbol default
      // would be invisible to the parse above, so every annotation must carry
      // an explicit `symbol:` for the comparison to be exhaustive.
      expect(bound, hasLength('@Native<'.allMatches(source).length));
      expect(bound, isNotEmpty);
      expect(symbols.toSet(), equals(bound.toSet()));
      expect(symbols, hasLength(bound.toSet().length));
    });
  });
}
