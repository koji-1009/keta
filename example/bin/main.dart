import 'dart:io';

import 'package:keta_example/app.dart';
import 'package:keta_example/env.dart';

Future<void> main() async {
  // serve boots one env per isolate; Env.boot is a static tear-off, so the same
  // call scales horizontally by raising `isolates`.
  final server = await buildApp().serve(Env.boot, port: 8080, isolates: 1);
  stdout.writeln('keta_example listening on :8080');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
