/// Link hook for keta_native: receives the static `libcrypto` archive the
/// build hook routes here when linking is enabled (AOT `dart build`), and
/// tree-shakes it down to the symbols the `@Native` bindings reference —
/// derived at link time from `lib/src/ffi/libcrypto.dart` by
/// `hook/symbols.dart`, never hand-listed — before emitting the final
/// per-asset dynamic library.
///
/// When the app was compiled with the `record-use` experiment, the keep-list
/// narrows further to the bindings the AOT compiler recorded as reachable:
/// an app that only verifies carries no key-generation or signing code.
/// Without recordings the full binding surface is kept.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:record_use/record_use.dart' show Library, Method;

import 'symbols.dart';

const _bindingsLibrary = Library('package:keta_native/src/ffi/libcrypto.dart');

void main(List<String> args) async {
  await link(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final assets = input.assets.code;
    if (assets.isEmpty) return;

    final logger = Logger('keta_native.link')
      ..onRecord.listen((record) => stderr.writeln(record.message));

    // Not part of this hook's import graph, so registered explicitly: the
    // keep-list must re-derive when the bindings change.
    output.dependencies.add(input.packageRoot.resolve(bindingsPath));

    final bindings = readBindings(input.packageRoot);
    final uses = input.recordedUses;
    final symbolsToKeep = [
      for (final binding in bindings)
        if (uses == null ||
            (uses.calls[Method(binding.dartName, _bindingsLibrary)] ?? const [])
                .isNotEmpty)
          binding.symbol,
    ];
    logger.info(
      uses == null
          ? 'No recorded usages; keeping all ${symbolsToKeep.length} bound '
                'symbols.'
          : 'Recorded usages: keeping ${symbolsToKeep.length} of '
                '${bindings.length} bound symbols.',
    );

    final targetOS = input.config.code.targetOS;
    final linker = CLinker.library(
      name: 'keta_native_crypto',
      assetName: 'src/ffi/libcrypto.dart',
      sources: [for (final asset in assets) asset.file!.toFilePath()],
      linkerOptions: LinkerOptions.treeshake(symbolsToKeep: symbolsToKeep),
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
