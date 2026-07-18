library;

import 'dart:async';
import 'dart:isolate';

import 'bus.dart';
import 'local_delivery.dart';

/// A [Bus] whose messages span the isolates of one process: a message published
/// in any connected isolate reaches subscribers in **every** connected isolate,
/// still at-most-once.
///
/// ## Topology
///
/// One isolate holds the **hub** ([IsolateBus.hub]); every other isolate holds
/// a **connection** ([IsolateBus.connect]) attached to that hub over a
/// [SendPort]. This matches keta's `serve(isolates: n)`: create the hub in the
/// main isolate, capture its [connectPort], and pass that port to each worker
/// so the worker can `IsolateBus.connect(port)`.
///
/// The hub fans every published message out to every connected isolate; each
/// isolate then filters locally to its own subscribers (there is no
/// subscription-registration protocol). This keeps the wiring trivial at the
/// cost of sending a message to an isolate even when that isolate has no
/// subscriber for the topic — an accepted trade for a single-process,
/// few-isolates bus.
///
/// ## What crosses the boundary
///
/// Only canonical JSON messages cross isolates (validated at [publish]), so
/// every message is transferable by construction.
///
/// ## Delivery and drops
///
/// At-most-once, as for any [Bus]. A message published before a connection has
/// finished attaching, or after it has closed, is simply not delivered to that
/// isolate — dropped silently, never buffered.
///
/// ## Lifecycle
///
/// Closing the hub ([close]) tells every live connection to terminate: their
/// subscription streams close and the connection becomes closed. Closing a
/// connection detaches it from the hub gracefully. A connection that dies
/// **abruptly** (its isolate is killed or crashes) is *not* detected — Dart
/// delivers no error for a [SendPort] whose isolate is gone, so the hub keeps a
/// dead connection's port in its set and every fan-out still (harmlessly)
/// sends to it, a no-op that neither errors nor delivers. keta_bus deliberately
/// ships no keepalive/liveness protocol; graceful [close] is the supported way
/// to detach, and it is what `serve`'s orderly shutdown uses.
abstract class IsolateBus implements Bus {
  IsolateBus._();

  /// Creates the hub in the current (main) isolate. Read [connectPort] and hand
  /// it to each worker isolate.
  factory IsolateBus.hub() = _HubBus;

  /// Attaches the current isolate to the hub reachable through [connectPort]
  /// (the value read from [IsolateBus.hub]'s [connectPort] in the main isolate).
  factory IsolateBus.connect(SendPort connectPort) = _WorkerBus;

  /// The [SendPort] a worker passes to [IsolateBus.connect]. Available only on
  /// the hub; a connection has no port to hand out and throws [StateError].
  SendPort get connectPort;
}

/// Fields and logic shared by both roles: the in-isolate delivery core, the
/// closed flag, and the `subscribe`/validation contract.
abstract class _IsolateBusBase extends IsolateBus {
  _IsolateBusBase() : super._();

  final LocalDelivery _delivery = LocalDelivery();
  bool _closed = false;

  @override
  Stream<Object?> subscribe(String topic) {
    _ensureOpen();
    checkTopic(topic);
    return _delivery.subscribe(topic);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('IsolateBus is closed');
    }
  }
}

/// The hub side: owns the inbox that connections attach/publish to, and fans
/// every message out to local subscribers plus every connection.
final class _HubBus extends _IsolateBusBase {
  _HubBus() {
    _inboxSub = _inbox.listen(_onMessage);
  }

  final ReceivePort _inbox = ReceivePort();
  final Set<SendPort> _connections = {};
  late final StreamSubscription<Object?> _inboxSub;

  @override
  SendPort get connectPort => _inbox.sendPort;

  @override
  void publish(String topic, Object? message) {
    _ensureOpen();
    checkTopic(topic);
    checkJsonValue(message);
    _fanout(topic, message);
  }

  void _fanout(String topic, Object? message) {
    _delivery.deliver(topic, message);
    for (final connection in _connections) {
      connection.send(('msg', topic, message));
    }
  }

  void _onMessage(Object? message) {
    switch (message) {
      case ('attach', final SendPort port):
        _connections.add(port);
      case ('detach', final SendPort port):
        _connections.remove(port);
      case ('pub', final String topic, final Object? payload):
        // Already validated in the publishing isolate; forward as-is.
        _fanout(topic, payload);
      default:
      // Unknown envelope from a mismatched peer — ignore rather than crash the
      // hub's inbox loop.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inboxSub.cancel();
    for (final connection in _connections) {
      connection.send(const ('close',));
    }
    _connections.clear();
    _inbox.close();
    await _delivery.close();
  }
}

/// The connection side: publishes go to the hub (which echoes them back so this
/// isolate's own subscribers see them too), and messages fanned out by the hub
/// are delivered locally.
final class _WorkerBus extends _IsolateBusBase {
  _WorkerBus(this._hub) {
    _fromHubSub = _fromHub.listen(_onMessage);
    _hub.send(('attach', _fromHub.sendPort));
  }

  final SendPort _hub;
  final ReceivePort _fromHub = ReceivePort();
  late final StreamSubscription<Object?> _fromHubSub;

  @override
  SendPort get connectPort => throw StateError(
    'connectPort is available only on the hub (IsolateBus.hub()); a connection '
    'created with IsolateBus.connect() has no port to hand out',
  );

  @override
  void publish(String topic, Object? message) {
    _ensureOpen();
    checkTopic(topic);
    checkJsonValue(message);
    _hub.send(('pub', topic, message));
  }

  void _onMessage(Object? message) {
    switch (message) {
      case ('msg', final String topic, final Object? payload):
        _delivery.deliver(topic, payload);
      case ('close',):
        // The hub is shutting down: terminate this connection's subscriptions.
        unawaited(_closeLocal());
      default:
      // Unknown envelope — ignore.
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // Detach gracefully so the hub drops this connection's port immediately,
    // rather than retaining it until hub close.
    _hub.send(('detach', _fromHub.sendPort));
    await _closeLocal();
  }

  Future<void> _closeLocal() async {
    if (_closed) return;
    _closed = true;
    await _fromHubSub.cancel();
    _fromHub.close();
    await _delivery.close();
  }
}
