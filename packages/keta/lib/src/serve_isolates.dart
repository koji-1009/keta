library;

import 'dart:async';
import 'dart:isolate';

import 'app.dart';
import 'h1_transport.dart';
import 'log.dart';
import 'transport.dart';

/// Runs the app on [isolates] listeners, each booting its own env.
///
/// [setup] is invoked once per isolate — on the current isolate and inside each
/// spawned one — to build that isolate's [App] and env. It must be sendable: a
/// top-level or static function, or a closure capturing only sendable state.
/// Every isolate binds the same [port] with `SO_REUSEPORT`, so the OS balances
/// connections across them. Each isolate owns and later closes its own env.
///
/// The returned [Server] shuts every isolate down: on [Server.shutdown] the
/// current isolate stops accepting and each child drains within the grace
/// window, closes its env, and exits.
Future<Server> serveIsolates<E>(
  FutureOr<(App<E>, E)> Function() setup, {
  int isolates = 1,
  int port = 8080,
  int maxBodyBytes = 1 << 20,
}) async {
  if (isolates < 1) {
    throw ArgumentError.value(isolates, 'isolates', 'must be >= 1');
  }
  // Bind the current isolate first, so a configuration error surfaces here
  // before any child is spawned.
  final (app, env) = await setup();
  final router = app.compile(env, maxBodyBytes: maxBodyBytes);
  final transport = await const H1Transport().bind(port, router.dispatch);

  final children = <_Child>[];
  for (var i = 1; i < isolates; i++) {
    children.add(await _spawn<E>(setup, port, maxBodyBytes));
  }
  return _IsolatesServer<E>(env, router.baseLog, transport, children);
}

class _Child {
  final Isolate isolate;
  final SendPort control;

  _Child(this.isolate, this.control);
}

Future<_Child> _spawn<E>(
  FutureOr<(App<E>, E)> Function() setup,
  int port,
  int maxBodyBytes,
) async {
  final ready = ReceivePort();
  final errors = ReceivePort();
  final isolate = await Isolate.spawn(
    _entry<E>,
    (setup, port, maxBodyBytes, ready.sendPort),
    onError: errors.sendPort,
    errorsAreFatal: true,
  );
  try {
    // Whichever arrives first: the child's control port (bound) or an error.
    final control = await Future.any([
      ready.first,
      errors.first.then((e) => throw StateError('worker failed to start: $e')),
    ]);
    return _Child(isolate, control as SendPort);
  } finally {
    ready.close();
    errors.close();
  }
}

Future<void> _entry<E>(
    (FutureOr<(App<E>, E)> Function(), int, int, SendPort) args) async {
  final (setup, port, maxBodyBytes, ready) = args;
  final (app, env) = await setup();
  final router = app.compile(env, maxBodyBytes: maxBodyBytes);
  final transport = await const H1Transport().bind(port, router.dispatch);

  final control = ReceivePort();
  ready.send(control.sendPort);
  final message = await control.first as (SendPort, int);
  final (ack, graceMs) = message;
  await transport.close(grace: Duration(milliseconds: graceMs));
  if (env is Disposable) await env.close();
  await router.baseLog.flush();
  control.close();
  ack.send(null);
}

class _IsolatesServer<E> implements Server {
  final E _env;
  final Log _baseLog;
  final TransportServer _transport;
  final List<_Child> _children;

  _IsolatesServer(this._env, this._baseLog, this._transport, this._children);

  @override
  Future<void> shutdown({Duration grace = const Duration(seconds: 30)}) async {
    final acks = <Future<void>>[];
    for (final child in _children) {
      final ack = ReceivePort();
      child.control.send((ack.sendPort, grace.inMilliseconds));
      acks.add(ack.first.then((_) => ack.close()));
    }
    await _transport.close(grace: grace);
    if (_env is Disposable) await (_env as Disposable).close();
    await _baseLog.flush();
    if (_baseLog is StdoutLog) _baseLog.dispose();
    await Future.wait(acks)
        .timeout(grace + const Duration(seconds: 5), onTimeout: () => const []);
    for (final child in _children) {
      child.isolate.kill(priority: Isolate.immediate);
    }
  }
}
