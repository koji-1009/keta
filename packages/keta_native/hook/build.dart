/// Build hook for keta_native: compiles BoringSSL's `libcrypto` from a pinned
/// commit into a per-asset dynamic library, exposed to Dart FFI as the code
/// asset `src/ffi/libcrypto.dart`.
///
/// The source is shallow-fetched (git) into the hook's shared output directory
/// on the first build and reused afterwards, keyed by a marker file carrying
/// the pinned commit — so subsequent builds are offline and the fetch is
/// idempotent. Compilation is a single [CBuilder.library] call over BoringSSL's
/// checked-in `gen/sources.json` recipe.
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

/// google/boringssl `main` at 2026-07-17. `gen/sources.json` is checked in at
/// this commit, so no perl/go/cmake generation step is required.
const _boringSslCommit = '922c15f36cc75db5af33c46f9ea8934553fb808e';
const _boringSslRepoUrl = 'https://github.com/google/boringssl.git';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final logger = Logger('keta_native.build')
      ..onRecord.listen((record) => stderr.writeln(record.message));

    // Platform gate: BoringSSL here is built for macOS and Linux only. Windows
    // (nasm) and the mobile targets are out of keta's server platform matrix.
    final targetOS = input.config.code.targetOS;
    if (targetOS != OS.macOS && targetOS != OS.linux) {
      throw UnsupportedError(
        'keta_native builds BoringSSL for macOS and Linux only; target OS '
        '"$targetOS" is not supported. This is a server-side native layer.',
      );
    }

    // The shared output directory persists across per-config builds and is
    // owned solely by this hook; the hook runner serializes concurrent
    // invocations, so the checkout is written once and reused.
    final checkout = Directory.fromUri(
      input.outputDirectoryShared.resolve('boringssl-checkout/'),
    );
    await _ensureCheckout(checkout, logger);

    // gen/sources.json is checked in at the pinned commit. It groups the
    // libcrypto build into two targets: `bcm` (the FIPS module translation
    // unit plus its per-arch asm) and `crypto` (everything else). Compiling
    // bcm.srcs + bcm.asm + crypto.srcs + crypto.asm together reproduces the
    // non-FIPS `crypto` library CMakeLists.txt builds from the same lists.
    final sources =
        jsonDecode(
              await File.fromUri(
                checkout.uri.resolve('gen/sources.json'),
              ).readAsString(),
            )
            as Map<String, Object?>;

    List<String> filesOf(String target, String key) => [
      for (final path
          in (sources[target]! as Map<String, Object?>)[key]! as List<Object?>)
        checkout.uri.resolve(path! as String).toFilePath(),
    ];

    final compileSources = <String>[
      ...filesOf('bcm', 'srcs'),
      ...filesOf('bcm', 'asm'),
      ...filesOf('crypto', 'srcs'),
      ...filesOf('crypto', 'asm'),
    ];

    final builder = CBuilder.library(
      name: 'keta_native_crypto',
      assetName: 'src/ffi/libcrypto.dart',
      sources: compileSources,
      includes: [checkout.uri.resolve('include/').toFilePath()],
      // Deliberately NOT `language: Language.cpp`: that would inject a global
      // `-x c++` and force the `.S` assembly files to be parsed as C++.
      // Leaving the default (C) lets clang pick the language per file
      // extension — `.cc` compiled as C++, `.S` assembled — which is exactly
      // how this mixed source list must build.
      std: 'c++17', // CMakeLists.txt: CMAKE_CXX_STANDARD 17 (C++17 required).
      defines: {
        // CMakeLists.txt sets -DBORINGSSL_IMPLEMENTATION on the libcrypto /
        // fipsmodule targets; internal headers gate exported symbols on it.
        'BORINGSSL_IMPLEMENTATION': null,
        // Linux exposes pthread_rwlock_t only under this feature flag; on Apple
        // it instead *disables* APIs BoringSSL uses, so upstream scopes it to
        // Linux (CMakeLists.txt lines 124-130).
        if (targetOS == OS.linux) '_XOPEN_SOURCE': '700',
      },
      // Upstream compiles libcrypto's C++ with -fno-exceptions -fno-rtti
      // (CMakeLists.txt NO_CXX_RUNTIME_FLAGS) to keep its C++ runtime footprint
      // tiny; the .S inputs ignore these with a harmless unused-arg warning.
      flags: const ['-fno-exceptions', '-fno-rtti'],
      // A `.cc` source list still needs the C++ runtime linked: BoringSSL's
      // C++ destructors reference `operator delete`. We omit `language: cpp`
      // (its global `-x c++` would break the `.S` inputs), so the C driver
      // does not auto-link it — name the platform C++ library explicitly.
      // `libraries` entries are emitted after the objects (correct link order).
      libraries: [targetOS == OS.macOS ? 'c++' : 'stdc++'],
    );

    await builder.run(input: input, output: output, logger: logger);
  });
}

/// Ensures [checkout] holds the pinned BoringSSL commit.
///
/// Idempotent: a marker file records the checked-out commit; when it already
/// matches, the (network) fetch is skipped, so builds after the first are
/// offline. Any partial/mismatched state is wiped and re-fetched.
Future<void> _ensureCheckout(Directory checkout, Logger logger) async {
  final marker = File.fromUri(checkout.uri.resolve('.keta_commit'));
  if (marker.existsSync() &&
      (await marker.readAsString()).trim() == _boringSslCommit) {
    logger.info('BoringSSL $_boringSslCommit already present; skipping fetch.');
    return;
  }

  logger.info('Fetching BoringSSL $_boringSslCommit into ${checkout.path}');
  if (checkout.existsSync()) {
    checkout.deleteSync(recursive: true);
  }
  checkout.createSync(recursive: true);

  Future<void> git(List<String> arguments) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: checkout.path,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'git',
        arguments,
        'BoringSSL fetch step failed:\n${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  // Shallow-fetch exactly the pinned commit — no history, no other refs.
  await git(['init', '--quiet']);
  await git([
    'fetch',
    '--depth',
    '1',
    '--quiet',
    _boringSslRepoUrl,
    _boringSslCommit,
  ]);
  await git(['checkout', '--quiet', 'FETCH_HEAD']);

  marker.writeAsStringSync('$_boringSslCommit\n');
  logger.info('BoringSSL $_boringSslCommit checked out.');
}
