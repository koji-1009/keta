/// Canary: the exact package:postgres message literals keta_rds keys its
/// socket-death 503 off still exist verbatim in the installed driver source.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:keta_rds/src/errors.dart';
import 'package:test/test.dart';

/// keta_rds recognises a mid-session socket death by matching two exact
/// package:postgres message strings (see [socketErrorPrefix] and
/// [socketClosedMessage] in `lib/src/errors.dart`): the driver gives those
/// disconnects no SQLSTATE and only its default severity, so the text is the
/// sole signal that the 503-worthy "connection lost" condition happened. That
/// makes the match co-rot with the driver — a patch release that rewords either
/// line would silently downgrade the disconnect from a 503 to a raw 500, and no
/// unit test that feeds *synthesised* messages in would notice, because those
/// tests hand-copy the very strings under suspicion.
///
/// This canary closes that gap by asserting the literals still appear verbatim
/// in the INSTALLED driver source. It resolves the driver via the package
/// config (the same resolution `dart` itself uses), so it tracks whatever
/// version `dart pub upgrade` last wrote — no pinned path, no pub-cache layout
/// assumption. If either string has moved on, this fails loudly and the fix is
/// to re-verify the driver's disconnect handling and update both the constants
/// in `errors.dart` and this canary together.
void main() {
  test('the socket-death messages keta_rds matches still exist verbatim in '
      'the installed package:postgres source', () async {
    final source = await _driverSource();

    expect(
      source,
      contains(socketErrorPrefix),
      reason:
          'package:postgres no longer contains the literal '
          '"$socketErrorPrefix". keta_rds keys its mid-session "connection '
          'lost" 503 off this exact string (errors.dart socketErrorPrefix); if '
          'the driver reworded it, that match now silently fails and the '
          'disconnect degrades to a raw 500. Re-check the driver\'s socket-error '
          'handling and update socketErrorPrefix in errors.dart to the new '
          'wording (and this canary with it).',
    );
    expect(
      source,
      contains(socketClosedMessage),
      reason:
          'package:postgres no longer contains the literal '
          '"$socketClosedMessage". Same failure mode as socketErrorPrefix: '
          'update socketClosedMessage in errors.dart to the new wording.',
    );
  });
}

/// Reads every `.dart` file in the installed package:postgres `lib/` tree and
/// returns them concatenated, so a caller can assert a literal appears
/// *somewhere* in the driver (robust to the driver relocating the code between
/// files, as long as the wording survives — which is exactly what the runtime
/// match depends on).
///
/// Resolution goes through the package config the current isolate is running
/// under ([Isolate.packageConfig]), which in this pub workspace is the single
/// `.dart_tool/package_config.json` at the workspace root — found without
/// hard-coding where it sits. Every failure to locate the source throws with a
/// concrete pointer to what to check, so the source genuinely being missing is
/// never mistaken for the literals being present (it must never pass silently).
Future<String> _driverSource() async {
  final configUri = await Isolate.packageConfig;
  if (configUri == null) {
    fail(
      'Could not locate the package config for this isolate '
      '(Isolate.packageConfig returned null). Run this test via `dart test` '
      'from packages/keta_rds so a .dart_tool/package_config.json is in scope.',
    );
  }

  final configFile = File.fromUri(configUri);
  if (!configFile.existsSync()) {
    fail(
      'The package config at $configUri does not exist on disk. Run '
      '`dart pub get` in the workspace to regenerate it.',
    );
  }

  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, Object?>;
  final packages = (config['packages'] as List).cast<Map<String, Object?>>();
  final postgres = packages.cast<Map<String, Object?>?>().firstWhere(
    (p) => p!['name'] == 'postgres',
    orElse: () => null,
  );
  if (postgres == null) {
    fail(
      'No "postgres" entry in the package config ($configUri). keta_rds '
      'depends on package:postgres — check pubspec.yaml and run `dart pub get`.',
    );
  }

  // rootUri may be absolute (a pub-cache path) or relative to the config file;
  // resolve() handles both, and appending 'lib/' via packageUri gives the
  // source root regardless of the cache's on-disk shape.
  final rawRoot = postgres['rootUri'] as String;
  final root = configUri.resolve(rawRoot.endsWith('/') ? rawRoot : '$rawRoot/');
  final packageUri = (postgres['packageUri'] as String?) ?? 'lib/';
  final libDir = Directory.fromUri(root.resolve(packageUri));
  if (!libDir.existsSync()) {
    fail(
      'The resolved package:postgres source directory does not exist: '
      '${libDir.path} (from rootUri "$rawRoot" in $configUri). The pub cache '
      'may be corrupt — run `dart pub get`.',
    );
  }

  final buffer = StringBuffer();
  var dartFiles = 0;
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      dartFiles++;
      buffer
        ..write(entity.readAsStringSync())
        ..write('\n');
    }
  }
  if (dartFiles == 0) {
    fail(
      'Found no .dart files under ${libDir.path}. The package:postgres install '
      'looks empty or corrupt — run `dart pub get`.',
    );
  }
  return buffer.toString();
}
