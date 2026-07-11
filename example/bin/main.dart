import 'dart:io';

import 'package:keta_example/app.dart';
import 'package:keta_example/env.dart';

Future<void> main() async {
  final env = await Env.boot();
  final app = buildApp();
  final server = await app.serve(env, port: 8080);
  stdout.writeln('keta_example listening on :8080');

  // For horizontal scaling, replace the two lines above with:
  //   final server = await serveIsolates(() async => (buildApp(), await Env.boot()),
  //       port: 8080, isolates: 4);
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
