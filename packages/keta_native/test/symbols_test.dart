import 'dart:io';

import 'package:test/test.dart';

import '../hook/symbols.dart';

void main() {
  group('readBoundSymbols', () {
    test('derives a non-empty, duplicate-free keep-list from the bindings', () {
      final symbols = readBoundSymbols(Directory.current.uri);
      expect(symbols, isNotEmpty);
      expect(symbols.toSet(), hasLength(symbols.length));
    });

    // The failure mode the parser guards: a binding relying on @Native's
    // implicit Dart-name-as-symbol default resolves in JIT runs (full
    // library bundled) but ships an AOT library missing its symbol. The
    // parser must reject it at build time, not silently under-count.
    test('rejects a binding without an explicit symbol:', () {
      final root = Directory.systemTemp.createTempSync('keta_native_symbols');
      addTearDown(() => root.deleteSync(recursive: true));
      File.fromUri(root.uri.resolve(bindingsPath))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
@Native<Int Function()>(symbol: 'BN_new')
external int BN_new();
@Native<Int Function()>()
external int BN_cmp();
''');
      expect(() => readBoundSymbols(root.uri), throwsStateError);
    });
  });
}
