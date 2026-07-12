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
      child?.kill();
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
