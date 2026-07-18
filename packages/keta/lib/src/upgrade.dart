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
  /// Constructs and validates the declaration. Throws [ArgumentError] when
  /// [maxIdle] or [maxLifetime] is given and is not positive — a non-positive
  /// bound is an authoring defect, the same posture keta takes for a malformed
  /// [SseEvent] field or a non-positive SSE `maxIdle`/`maxLifetime`.
  Upgrade(
    this.onConnected, {
    this.subprotocol,
    this.maxIdle,
    this.maxLifetime,
  }) {
    if (maxIdle != null && maxIdle! <= Duration.zero) {
      throw ArgumentError.value(maxIdle, 'maxIdle', 'maxIdle must be positive');
    }
    if (maxLifetime != null && maxLifetime! <= Duration.zero) {
      throw ArgumentError.value(
        maxLifetime,
        'maxLifetime',
        'maxLifetime must be positive',
      );
    }
  }

  /// Invoked once, by the realizing transport, with the switched channel. It may
  /// return a `Future` that lives for the whole connection (the ergonomic echo
  /// loop `await for (m in channel.messages) channel.send(m)`); the transport
  /// does not hold the originating request open for that lifetime — it tracks
  /// the socket separately so graceful shutdown can still bound it.
  ///
  /// The channel handed here is not always the transport's raw channel: when
  /// [maxIdle] or [maxLifetime] is set, [realizeUpgrade] (called by every
  /// realizing transport in place of invoking this field directly) wraps it
  /// first. The handler cannot tell the difference — both are just
  /// [UpgradedChannel] — which is the point: the bound is enforced without the
  /// handler opting into anything beyond passing [maxIdle]/[maxLifetime] here.
  final FutureOr<void> Function(UpgradedChannel channel) onConnected;

  /// The WebSocket subprotocol to select during the handshake, or null to select
  /// none. When set, the client must have offered it, otherwise the handshake
  /// fails — a declared subprotocol is a contract, not a hint.
  final String? subprotocol;

  /// Opt-in idle-close bound (E-21a), null by default (no bound — current
  /// behavior unchanged; keta never starts a timer the caller did not ask for).
  ///
  /// The clock resets on every INBOUND frame — one arriving from the peer via
  /// [UpgradedChannel.messages] — and only that. Sending a frame via
  /// [UpgradedChannel.send] does NOT reset it: a send proves nothing about
  /// whether the peer is still there to receive it, whereas a frame *from* the
  /// peer is direct proof of life. This mirrors the SSE `maxIdle` stance, where
  /// server-originated keep-alive traffic likewise does not count — in both
  /// cases, only traffic that could only originate from something still alive
  /// on the other end resets the clock. A push-only handler that never reads
  /// [UpgradedChannel.messages] therefore gets no idle resets at all and will
  /// be reaped at [maxIdle] regardless of how much it sends — which is exactly
  /// the abandoned/unresponsive-peer case this bound exists to catch.
  ///
  /// On expiry the channel is closed server-side with WebSocket close code 1001
  /// ("Going Away") — the same code keta's graceful shutdown already sends an
  /// open socket (see `H1Transport`'s `close`), chosen for consistency: from
  /// the peer's perspective both are "the server is ending this connection",
  /// not a protocol fault of the peer's.
  final Duration? maxIdle;

  /// Opt-in absolute lifetime cap (E-21a), null by default. Added for symmetry
  /// with SSE's `maxLifetime` because it falls out of the same timer
  /// infrastructure [maxIdle] already needs, at no extra conceptual cost: unlike
  /// [maxIdle], it needs no stance on what counts as traffic — it is a plain
  /// wall-clock deadline from the moment the channel is realized, regardless of
  /// activity in either direction. Fires even if frames are flowing right up to
  /// the deadline. Closes with the same 1001 code as [maxIdle]'s expiry.
  final Duration? maxLifetime;
}

/// The close code sent when a bounded channel expires ([Upgrade.maxIdle] or
/// [Upgrade.maxLifetime]): RFC 6455's 1001 "Going Away" — reused rather than
/// inventing a new one so a client sees one consistent "server-initiated, not
/// a protocol fault of yours" close code across every server-driven teardown
/// keta has. Graceful shutdown already answers an open socket with this same
/// code (`H1Transport.close`); an expiry is the same kind of event from the
/// peer's point of view — the server ending the connection — just triggered by
/// a bound instead of a shutdown.
const int _expiryCloseCode = 1001;

/// Realizes [upgrade] against [raw]: invokes [Upgrade.onConnected] with [raw]
/// itself when neither [Upgrade.maxIdle] nor [Upgrade.maxLifetime] is set (the
/// zero-overhead default path — no wrapper, no timer, nothing that could pin
/// the isolate), or with an idle/lifetime-bounded wrapper otherwise. Every
/// realizing transport (`H1Transport`, `TestClient`) calls this instead of
/// `upgrade.onConnected` directly, so the bound is enforced uniformly
/// regardless of transport — the wrapper only ever touches the neutral
/// [UpgradedChannel] surface (`messages`, `send`, `close`, `done`), so
/// `dart:io` stays out of this seam exactly as [UpgradedChannel] itself
/// demands.
///
/// Not exported from `keta.dart`; reachable only via
/// `package:keta/src/upgrade.dart` — the same visibility discipline
/// `debugWebSocketChannel` uses in `h1_transport.dart`.
FutureOr<void> realizeUpgrade(Upgrade upgrade, UpgradedChannel raw) {
  if (upgrade.maxIdle == null && upgrade.maxLifetime == null) {
    return upgrade.onConnected(raw);
  }
  return upgrade.onConnected(
    _BoundedChannel(raw, idle: upgrade.maxIdle, lifetime: upgrade.maxLifetime),
  );
}

/// Wraps [_inner] with idle/lifetime bounds, expiring the connection with a
/// server-initiated close (see [_expiryCloseCode]) when either fires. Built
/// once by [realizeUpgrade] and handed to the handler in place of the
/// transport's raw channel; the handler cannot tell the difference — both are
/// just [UpgradedChannel].
///
/// The `messages` stream is *tapped*, not re-subscribed: `_inner.messages.map`
/// preserves the underlying channel's exact listen/cancel timing (any
/// `onListen`/`onCancel` it has still fire exactly when the handler
/// subscribes/cancels the *mapped* stream, because `Stream.map` subscribes to
/// its source lazily, on the outer stream's own listen, and forwards
/// cancel/pause/resume in lockstep). That is load-bearing here: it is exactly
/// what lets this wrapper sit in front of `_IoWebSocketChannel`'s watch-only,
/// forward-or-drop design (`h1_transport.dart`) without disturbing it — this
/// wrapper never becomes a second subscriber and never changes when a frame is
/// forwarded vs. dropped, only what happens to an already-forwarded frame.
class _BoundedChannel implements UpgradedChannel {
  _BoundedChannel(this._inner, {this.idle, Duration? lifetime}) {
    if (lifetime != null) {
      _lifetimeTimer = Timer(lifetime, () => _expire('lifetime exceeded'));
    }
    _armIdle();
    // However the underlying channel ends — peer close, local close, or a
    // transport-observed drop — stop both timers so neither fires (a harmless
    // but wasted `close()`, since `close` is idempotent) after the connection
    // is already gone, and so no timer outlives the connection and pins the
    // isolate.
    unawaited(_inner.done.whenComplete(_cancelAll));
  }

  final UpgradedChannel _inner;

  /// This wrapper's [Upgrade.maxIdle] value, under a shorter field name.
  final Duration? idle;
  Timer? _idleTimer;
  Timer? _lifetimeTimer;

  void _cancelAll() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _lifetimeTimer?.cancel();
    _lifetimeTimer = null;
  }

  void _armIdle() {
    final maxIdle = idle;
    if (maxIdle == null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(maxIdle, () => _expire('idle timeout exceeded'));
  }

  // Routes through this wrapper's own `close` (not `_inner.close` directly) so
  // the sibling timer is cancelled synchronously right here, rather than
  // waiting on `_inner.done` to complete asynchronously. Closing is idempotent
  // on every `UpgradedChannel` implementation (part of its documented
  // contract), so a race against a concurrent peer/local close just makes this
  // a no-op second close — never a double teardown.
  void _expire(String reason) {
    unawaited(close(_expiryCloseCode, reason));
  }

  @override
  Stream<Object> get messages => _inner.messages.map((message) {
    _armIdle(); // an inbound frame — proof of life — resets the idle clock
    return message;
  });

  @override
  void send(Object message) => _inner.send(message);

  @override
  Future<void> close([int? code, String? reason]) {
    _cancelAll();
    return _inner.close(code, reason);
  }

  @override
  Future<void> get done => _inner.done;
}
