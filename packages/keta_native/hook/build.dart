/// Build hook for keta_native: compiles BoringSSL's `libcrypto` from a pinned
/// commit, exposed to Dart FFI as the code asset `src/ffi/libcrypto.dart`.
///
/// Two output modes. With linking enabled (AOT `dart build`), the compile
/// emits a static archive routed to `hook/link.dart`, which tree-shakes it to
/// the symbols the `@Native` bindings use before producing the final dynamic
/// library. Without link hooks (JIT: `dart test` / `dart run`), the full
/// `libcrypto` is emitted as a dynamic library and bundled directly.
///
/// The pinned commit lives in `hook/boringssl_commit.txt` — a data file, so a
/// BoringSSL bump is a one-line change that never touches hook code. The file
/// is registered as a hook dependency, so the hook re-runs exactly when the
/// pin changes; `lib/src/version.dart` mirrors it, held in sync by
/// `test/version_test.dart`. The source arrives as GitHub's commit-addressed
/// archive tarball — one plain HTTPS GET served from the download path
/// (codeload), needing no git binary or smart-protocol exchange — into the
/// hook's shared output directory on the first build and is reused
/// afterwards, keyed by a marker file carrying the pinned commit, so
/// subsequent builds are offline and the fetch is idempotent. Compilation is
/// a single [CBuilder.library] call over BoringSSL's checked-in
/// `gen/sources.json` recipe.
library;

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

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

    final commit = _readPinnedCommit(input.packageRoot);
    // Registered as a hook dependency: the hooks runner re-runs this hook
    // (and thus the fetch) exactly when the pin file changes.
    output.dependencies.add(
      input.packageRoot.resolve('hook/boringssl_commit.txt'),
    );

    // The shared output directory persists across per-config builds and is
    // owned solely by this hook; the hook runner serializes concurrent
    // invocations, so the checkout is written once and reused.
    final checkout = Directory.fromUri(
      input.outputDirectoryShared.resolve('boringssl-checkout/'),
    );
    await _ensureCheckout(checkout, commit, logger);

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
      // -ffunction-sections/-fdata-sections give the link hook's --gc-sections
      // per-symbol granularity on Linux (macOS ld64 already strips per atom);
      // without them a kept symbol drags in its whole translation unit.
      flags: const [
        '-fno-exceptions',
        '-fno-rtti',
        '-ffunction-sections',
        '-fdata-sections',
      ],
      // A `.cc` source list still needs the C++ runtime linked: BoringSSL's
      // C++ destructors reference `operator delete`. We omit `language: cpp`
      // (its global `-x c++` would break the `.S` inputs), so the C driver
      // does not auto-link it — name the platform C++ library explicitly.
      // `libraries` entries are emitted after the objects (correct link order).
      libraries: [targetOS == OS.macOS ? 'c++' : 'stdc++'],
    );

    final linkingEnabled = input.config.linkingEnabled;
    await builder.run(
      input: input,
      output: output,
      logger: logger,
      routing: linkingEnabled
          ? [ToLinkHook(input.packageName)]
          : const [ToAppBundle()],
      linkModePreference: linkingEnabled
          ? LinkModePreference.static
          : LinkModePreference.dynamic,
    );
  });
}

/// Reads the pinned google/boringssl commit from `hook/boringssl_commit.txt`.
///
/// The pin must be a full 40-hex-char hash: abbreviations or refs would make
/// the fetch ambiguous and the marker comparison meaningless.
String _readPinnedCommit(Uri packageRoot) {
  final pinFile = File.fromUri(
    packageRoot.resolve('hook/boringssl_commit.txt'),
  );
  if (!pinFile.existsSync()) {
    throw StateError(
      'Missing ${pinFile.path}: it pins the google/boringssl commit this '
      'hook builds.',
    );
  }
  final commit = pinFile.readAsStringSync().trim();
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
    throw StateError(
      '${pinFile.path} must contain a full 40-character lowercase hex git '
      'commit hash, got: "$commit"',
    );
  }
  return commit;
}

/// Ensures [checkout] holds the pinned BoringSSL [commit].
///
/// Idempotent: a marker file records the checked-out commit; when it already
/// matches, the (network) fetch is skipped, so builds after the first are
/// offline. Any partial/mismatched state is wiped and re-fetched.
///
/// The commit-addressed tarball is immutable in content, so no ref
/// resolution or history is involved — the marker comparison alone decides
/// freshness.
Future<void> _ensureCheckout(
  Directory checkout,
  String commit,
  Logger logger,
) async {
  final marker = File.fromUri(checkout.uri.resolve('.keta_commit'));
  if (marker.existsSync() && (await marker.readAsString()).trim() == commit) {
    logger.info('BoringSSL $commit already present; skipping fetch.');
    return;
  }

  final url = Uri.parse(
    'https://github.com/google/boringssl/archive/$commit.tar.gz',
  );
  logger.info('Fetching $url into ${checkout.path}');
  if (checkout.existsSync()) {
    checkout.deleteSync(recursive: true);
  }
  checkout.createSync(recursive: true);

  final tarball = File.fromUri(
    checkout.parent.uri.resolve('boringssl-$commit.tar.gz'),
  );
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'BoringSSL tarball fetch failed: HTTP ${response.statusCode}',
        uri: url,
      );
    }
    await response.pipe(tarball.openWrite());
  } finally {
    client.close(force: true);
  }

  final tarArgs = [
    'xzf',
    tarball.path,
    '--strip-components=1',
    '-C',
    checkout.path,
  ];
  final result = await Process.run('tar', tarArgs);
  if (result.exitCode != 0) {
    throw ProcessException(
      'tar',
      tarArgs,
      'BoringSSL tarball extraction failed:\n${result.stdout}\n${result.stderr}',
      result.exitCode,
    );
  }
  tarball.deleteSync();

  marker.writeAsStringSync('$commit\n');
  logger.info('BoringSSL $commit checked out.');
}
