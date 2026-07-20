import 'dart:io';

import 'package:keta_native/keta_native.dart';
import 'package:test/test.dart';

void main() {
  group('boringsslCommit', () {
    // The constant mirrors hook/boringssl_commit.txt by hand. If the pin is
    // bumped without updating the constant, the exposed value would silently
    // lie about which BoringSSL backs the build, so this test forces the two
    // back in sync.
    test('matches the pin in hook/boringssl_commit.txt', () {
      final pinned = File(
        'hook/boringssl_commit.txt',
      ).readAsStringSync().trim();
      expect(boringsslCommit, pinned);
    });

    test('is a full 40-character hex hash', () {
      expect(boringsslCommit, matches(RegExp(r'^[0-9a-f]{40}$')));
    });
  });
}
