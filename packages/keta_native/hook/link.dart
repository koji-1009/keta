/// Link hook for keta_native: receives the static `libcrypto` archive the
/// build hook routes here when linking is enabled (AOT `dart build`), and
/// tree-shakes it down to the symbols the `@Native` bindings reference
/// (`hook/symbols.dart`) — dead-stripping everything of BoringSSL the
/// verify-oriented surface never calls — before emitting the final per-asset
/// dynamic library.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

import 'symbols.dart';

void main(List<String> args) async {
  await link(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final assets = input.assets.code;
    if (assets.isEmpty) return;

    final logger = Logger('keta_native.link')
      ..onRecord.listen((record) => stderr.writeln(record.message));

    final targetOS = input.config.code.targetOS;
    final linker = CLinker.library(
      name: 'keta_native_crypto',
      assetName: 'src/ffi/libcrypto.dart',
      sources: [for (final asset in assets) asset.file!.toFilePath()],
      linkerOptions: LinkerOptions.treeshake(symbolsToKeep: symbols),
      // The emitted asset must be a bundled dynamic library regardless of the
      // invoker's link-mode preference: `@Native` resolves it by asset id at
      // runtime.
      linkModePreference: LinkModePreference.dynamic,
      // Same constraint as the build hook's dynamic path: CLinker drives
      // clang as a C driver, which does not auto-link the C++ runtime that
      // BoringSSL's C++ destructors reference (`operator delete`).
      libraries: [targetOS == OS.macOS ? 'c++' : 'stdc++'],
    );
    await linker.run(input: input, output: output, logger: logger);
  });
}
