import 'dart:async';
import 'dart:io';

/// A zero-daemon dev server: runs `bin/main.dart` and restarts it whenever a
/// source file under `lib/` or `bin/` changes, debounced so a burst of saves
/// triggers one restart.
Future<void> main() async {
  Process? child;

  Future<void> start() async {
    child = await Process.start(Platform.resolvedExecutable, [
      'run',
      'bin/main.dart',
    ], mode: ProcessStartMode.inheritStdio);
  }

  await start();

  Timer? debounce;
  void scheduleRestart() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 150), () async {
      stdout.writeln('[dev] change detected — restarting');
      // The old process's SIGTERM triggers a graceful shutdown (up to 30s
      // grace), which means it can still hold the port well after `kill()`
      // returns — `kill()` only requests the signal, it does not wait for the
      // process to exit. Starting the replacement immediately raced it for the
      // port and lost under load ("address already in use"). Awaiting
      // exitCode makes the restart wait for the old process to actually be
      // gone before the new one binds.
      final old = child;
      old?.kill();
      await old?.exitCode;
      await start();
    });
  }

  for (final dir in ['lib', 'bin']) {
    final directory = Directory(dir);
    if (directory.existsSync()) {
      directory
          .watch(recursive: true)
          .where((e) => e.path.endsWith('.dart'))
          .listen((_) => scheduleRestart());
    }
  }

  await ProcessSignal.sigint.watch().first;
  child?.kill();
}
