import 'dart:io';

import 'package:test/test.dart';

import '../hook/symbols.dart';

void main() {
  group('readBindings', () {
    test('derives a non-empty, duplicate-free keep-list from the bindings', () {
      final bindings = readBindings(Directory.current.uri);
      expect(bindings, isNotEmpty);
      expect(
        bindings.map((binding) => binding.symbol).toSet(),
        hasLength(bindings.length),
      );
    });

    // The failure modes the parser guards, both invisible to JIT runs (which
    // bundle the full library): a binding relying on @Native's implicit
    // Dart-name-as-symbol default ships an AOT library missing its symbol; a
    // binding without @RecordUse() is never recorded, so a record-use build
    // treats it as unused and strips it. Both must fail the build.
    test('rejects a binding without an explicit symbol:', () {
      expect(
        () => readBindings(
          _fixture('''
@RecordUse()
@Native<Int Function()>(symbol: 'BN_new')
external int BN_new();
@RecordUse()
@Native<Int Function()>()
external int BN_cmp();
'''),
        ),
        throwsStateError,
      );
    });

    test('rejects a binding without @RecordUse()', () {
      expect(
        () => readBindings(
          _fixture('''
@RecordUse()
@Native<Int Function()>(symbol: 'BN_new')
external int BN_new();
@Native<Int Function()>(symbol: 'BN_cmp')
external int BN_cmp();
'''),
        ),
        throwsStateError,
      );
    });
  });
}

Uri _fixture(String source) {
  final root = Directory.systemTemp.createTempSync('keta_native_symbols');
  addTearDown(() => root.deleteSync(recursive: true));
  File.fromUri(root.uri.resolve(bindingsPath))
    ..createSync(recursive: true)
    ..writeAsStringSync(source);
  return root.uri;
}
