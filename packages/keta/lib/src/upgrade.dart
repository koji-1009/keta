library;

import 'dart:async';

/// A bidirectional message channel handed to an upgrade handler once a
/// [Transport] has switched the connection off HTTP and onto another protocol
/// (WebSocket over HTTP/1.1 today).
///
/// This is the transport-neutral socket value the note calls for: it names
/// *what a switched connection can do* — receive framed messages, send them,
/// close, observe closure — without naming *how*. `dart:io`'s `WebSocket` never
/// appears here (nor in `transport.dart`), so the seam stays value-shaped and a
/// future H2/H3 transport can satisfy the same surface. The concrete adapter
/// lives in the transport that produced it (`H1Transport` wraps `dart:io`'s
/// `WebSocket`); the core, the OpenAPI shadow, and the test harness all speak to
/// this interface alone.
///
/// It is deliberately minimal — no ping/pong, no backpressure knobs, no
/// subprotocol interrogation. Those are protocol-specific and would leak wire
/// concerns back through the seam; a handler that needs them belongs on a
/// transport-specific escape hatch, not on this neutral value.
abstract interface class UpgradedChannel {
  /// Inbound messages, each a `String` (a text frame) or a `List<int>` (a
  /// binary frame) — the two shapes WebSocket data frames carry. The stream
  /// closes when the peer (or this side) closes the connection; a mid-stream
  /// error is a transport failure surfaced verbatim. Single-subscription, like
  /// the underlying socket.
  Stream<Object> get messages;

  /// Sends [message] to the peer: a `String` is a text frame, a `List<int>` a
  /// binary frame. Sending after [close] is a state error, mirroring a
  /// `StreamSink` written past its close — the caller must gate on [done].
  void send(Object message);

  /// Closes the connection, optionally with a WebSocket close [code] (e.g. 1000
  /// normal, 1001 going away) and [reason]. Idempotent; completes when the close
  /// has been flushed. After it, [messages] is done and [done] has completed.
  Future<void> close([int? code, String? reason]);

  /// Completes when the connection is fully closed — by either peer, or by a
  /// transport-observed drop. This is how a handler learns the client walked
  /// away: it is the WebSocket counterpart of `TransportRequest.closed`, and
  /// unlike that best-effort signal it is reliable here, because a switched
  /// socket is no longer subject to `HttpServer`'s read-subscription pause.
  Future<void> get done;
}

/// The declaration that a handler answers a request by *upgrading* the
/// connection rather than returning a body — carried as a value on [Response]
/// (see `Response.upgrade`), never as a procedural hijack hook on `Context`.
///
/// This is the load-bearing shape of the whole feature. Because the intent to
/// upgrade is a value a handler *returns*, every declaration-driven middleware
/// (`enforceSecurity`, `recover`, `accessLog`) composes in front of it exactly
/// as it does for any other response: a security verifier can raise a plain 401
/// and the [Upgrade] is never even constructed. The connection callback is inert
/// data — [onConnected] is not invoked by anything until a [Transport] that can
/// actually switch protocols decides to act on it. A transport that cannot
/// (`TestClient`, the shelf bridge) sees an ordinary value and fails, or adapts,
/// loudly and predictably.
final class Upgrade {
  const Upgrade(this.onConnected, {this.subprotocol});

  /// Invoked once, by the realizing transport, with the switched channel. It may
  /// return a `Future` that lives for the whole connection (the ergonomic echo
  /// loop `await for (m in channel.messages) channel.send(m)`); the transport
  /// does not hold the originating request open for that lifetime — it tracks
  /// the socket separately so graceful shutdown can still bound it.
  final FutureOr<void> Function(UpgradedChannel channel) onConnected;

  /// The WebSocket subprotocol to select during the handshake, or null to select
  /// none. When set, the client must have offered it, otherwise the handshake
  /// fails — a declared subprotocol is a contract, not a hint.
  final String? subprotocol;
}
