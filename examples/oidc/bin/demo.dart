import 'dart:io';

import 'package:keta_oidc_example/demo.dart';

/// Runs the OIDC resource server with **no identity provider and no network**,
/// for a local try-out and as the CI smoke of the AOT-compiled native crypto.
///
/// [buildDemo] plays the IdP (see its doc): it generates a key, publishes it as
/// a `StaticJwks`, and mints one valid token — so the real `BoringSslVerifier`
/// path runs offline against a token this program prints. Contrast
/// `bin/main.dart`, which wires a *real* IdP over the network via
/// `HttpJwksSource.discover` and never mints anything.
///
/// Build it with `dart build cli` (not `dart compile exe`: keta_native and
/// package:sqlite3 carry build hooks, which only `dart build` runs):
///
/// ```
/// dart build cli -t bin/demo.dart -o build
/// PORT=8080 ./build/bundle/bin/demo
/// ```
Future<void> main() async {
  final demo = buildDemo();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;

  // isolates defaults to 1, so boot() runs on this isolate and the env's
  // in-process key never has to cross an isolate boundary — the demo is
  // single-key by nature (the one token below is what verifies).
  final server = await demo.app.serve(() async => demo.env, port: port);

  stdout
    ..writeln(
      'keta_oidc demo listening on :$port — no IdP, real BoringSSL '
      'verification.',
    )
    ..writeln(
      'A ready-to-use bearer token (RS256, valid 1h, scope '
      '"reports:read"):',
    )
    // A single machine-parsable line, so the CI smoke can capture the token.
    ..writeln('DEMO_TOKEN=${demo.token}')
    ..writeln('Try:')
    ..writeln('  curl localhost:$port/public')
    ..writeln(
      '  curl -H "Authorization: Bearer \$DEMO_TOKEN" '
      'localhost:$port/api/me',
    )
    ..writeln(
      '  curl -H "Authorization: Bearer \$DEMO_TOKEN" '
      'localhost:$port/api/reports',
    );

  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
