import 'dart:io';

import 'package:keta_auth_example/app.dart';
import 'package:keta_auth_example/env.dart';

Future<void> main() async {
  final server = await buildApp().serve(Env.boot, port: 8080);
  stdout.writeln('keta_auth_example listening on :8080');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
