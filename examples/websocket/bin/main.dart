import 'dart:io';

import 'package:keta_websocket_example/app.dart';

/// Runs the echo-WebSocket server:
///   dart run bin/main.dart
/// then connect with `ws://localhost:8080/ws/echo` and an `Authorization:
/// Bearer t-ok` header (any WebSocket client that can set request headers).
Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  // serve boots one env per isolate; Env.boot is a static tear-off, so the same
  // call scales horizontally by raising `isolates`.
  final server = await buildApp().serve(Env.boot, port: port, isolates: 1);
  stdout.writeln('keta_websocket_example listening on :$port');
  await ProcessSignal.sigterm.watch().first;
  await server.shutdown();
}
