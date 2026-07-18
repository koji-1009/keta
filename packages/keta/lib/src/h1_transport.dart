library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'response.dart';
import 'transport.dart';
import 'upgrade.dart';

/// The default HTTP/1.1 transport, built on `dart:io`. Uses only the SDK, so
/// the core's zero-dependency rule holds even with a transport bundled.
///
/// No path lets an error escape to the root zone: request handling, response
/// writing, and connection acceptance all report failures through [onError]
/// instead of terminating the isolate.
class H1Transport implements Transport {
  const H1Transport({this.address, this.onError});

  /// The bind address; defaults to all IPv4 interfaces when null.
  final Object? address;

  /// Reports transport-level failures (write errors, accept errors) instead of
  /// letting them reach the root zone. Falls back to stderr when null.
  final void Function(Object error, StackTrace stack)? onError;

  @override
  Future<TransportServer> bind(
    int port,
    FutureOr<Response> Function(TransportRequest) onRequest,
  ) async {
    // shared: true lets every isolate bind the same port and share the accept
    // queue, so serve(isolates: n) needs no extra coordination.
    final server = await HttpServer.bind(
      address ?? InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    return _H1Server(server, onRequest, onError ?? _toStderr);
  }
}

void _toStderr(Object error, StackTrace stack) {
  stderr.writeln('keta H1 transport error: $error');
}

class _H1Server implements TransportServer {
  _H1Server(this._server, this._onRequest, this._onError) {
    _server.listen(_accept, onError: _onError);
  }
  final HttpServer _server;
  final FutureOr<Response> Function(TransportRequest) _onRequest;
  final void Function(Object, StackTrace) _onError;
  final Set<Future<void>> _inFlight = {};

  // The wrapped requests currently being handled, parallel to `_inFlight`.
  // Tracked so graceful shutdown can signal each one to wind down (fire its
  // `closed`/abort seam) *before* the grace clock starts — the difference
  // between a cooperative streaming handler (SSE) ending promptly and one that
  // burns the whole grace only to be truncated by the forced close.
  final Set<_H1Request> _active = {};

  // Upgraded connections outlive the request that switched them, so they are NOT
  // tracked in `_inFlight` (which gates request/response draining). A WebSocket
  // could stay open for hours; if the handshake request stayed "in flight" for
  // that whole time, `close(grace)` would always burn the full grace window and
  // shutdown could hang on an idle chat socket. They are tracked here instead so
  // shutdown can force-close them after the request grace — bounding shutdown
  // without conflating a live socket with an unfinished request.
  final Set<WebSocket> _openSockets = {};

  void _accept(HttpRequest request) {
    // _handle never throws (it catches internally), but guard the derived
    // future so no rejection can reach the root zone.
    final done = _handle(request).catchError(_onError);
    _inFlight.add(done);
    done.whenComplete(() => _inFlight.remove(done));
  }

  Future<void> _handle(HttpRequest request) async {
    final wrapped = _H1Request(request);
    _active.add(wrapped);
    try {
      Response response;
      try {
        response = await _onRequest(wrapped);
      } catch (error, stack) {
        // The app applies a last-resort fallback, so this is defensive only.
        _onError(error, stack);
        response = Response(500, body: '');
      }
      final upgrade = response.upgrade;
      if (upgrade != null) {
        // The handler asked to switch protocols. This returns once the
        // handshake is done and the connection callback has been *started* —
        // not when the socket eventually closes — so the handshake request
        // leaves `_inFlight` promptly while the live socket is tracked in
        // `_openSockets`.
        await _switchProtocols(request, upgrade);
        return;
      }
      await _write(request.response, wrapped, response);
    } finally {
      _active.remove(wrapped);
    }
  }

  /// Realizes an [Upgrade] value against the concrete `dart:io` request this
  /// transport already holds — the piece that keeps `dart:io`'s `WebSocket` out
  /// of the transport-neutral seam: the switch happens here, behind [Transport],
  /// and only a neutral [UpgradedChannel] crosses back to the handler.
  Future<void> _switchProtocols(HttpRequest request, Upgrade upgrade) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      // An upgrade route was hit by a plain request (no `Upgrade: websocket`).
      // RFC 9110 §15.5.22 / RFC 6455 §4.2.2: answer 426 Upgrade Required and
      // advertise the protocol the client must switch to, so a browser hitting
      // the WS URL directly gets a precise, self-describing refusal rather than
      // a hung or malformed handshake.
      try {
        final out = request.response
          ..statusCode = HttpStatus.upgradeRequired
          ..headers.set(HttpHeaders.upgradeHeader, 'websocket')
          ..headers.set(HttpHeaders.connectionHeader, 'Upgrade');
        out.write('426 Upgrade Required: this endpoint speaks WebSocket');
        await out.close();
      } catch (error, stack) {
        _onError(error, stack);
      }
      return;
    }
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: _selectorFor(upgrade.subprotocol),
      );
    } catch (error, stack) {
      // A failed handshake (a bad key, or a subprotocol the client never
      // offered) — WebSocketTransformer has already written its own error
      // response and closed the socket. Log rather than swallow.
      _onError(error, stack);
      return;
    }
    _openSockets.add(ws);
    final channel = _IoWebSocketChannel(ws);
    // Drop the socket from the tracked set once the connection is closed,
    // however it closes (peer, us, or a drop). The channel's `done` is the
    // reliable signal — it fires on the *stream's* end, which a remote close
    // triggers, unlike `dart:io`'s WebSocket.done (the sink's done), which only
    // completes when THIS side closes (verified: a peer-initiated close leaves
    // the sink's done pending forever).
    unawaited(channel.done.whenComplete(() => _openSockets.remove(ws)));
    // Start the connection callback detached: it may loop for the socket's whole
    // lifetime, which must not keep the handshake request in `_inFlight`. A
    // throw from it is a handler defect — report it and close the socket so a
    // half-initialized connection does not linger.
    unawaited(
      Future.sync(() => realizeUpgrade(upgrade, channel)).then(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _onError(error, stack);
          ws.close(WebSocketStatus.internalServerError).catchError((_) {});
        },
      ),
    );
  }

  /// The handshake subprotocol selector: null when the route declares none.
  /// When it declares one, the client must have offered it (WebSocket
  /// negotiation cannot invent a subprotocol the client did not list), so a
  /// missing offer fails the handshake rather than silently downgrading.
  String Function(List<String>)? _selectorFor(String? subprotocol) {
    if (subprotocol == null) return null;
    return (offered) {
      if (offered.contains(subprotocol)) return subprotocol;
      throw WebSocketException(
        'client did not offer the required subprotocol "$subprotocol"',
      );
    };
  }

  Future<void> _write(
    HttpResponse out,
    _H1Request request,
    Response response,
  ) async {
    try {
      out.statusCode = response.status;
      response.headers.forEach((name, values) {
        // Framing is the Transport's to compute; user-supplied framing headers
        // are ignored so a stale content-length can never corrupt the wire.
        if (name == 'content-length' || name == 'transfer-encoding') return;
        out.headers.removeAll(name);
        for (final value in values) {
          out.headers.add(name, value);
        }
      });
      // Before framing the response, sever the connection if the handler left
      // a declared request body unread — otherwise dart:io would drain an
      // arbitrarily large upload at close (see [_H1Request.severIfBodyUnread]).
      request.severIfBodyUnread(out);
      final body = response.body;
      switch (body) {
        // A known-length body is framed with Content-Length; only a stream,
        // whose length is unknown up front, falls back to chunked framing
        // (contentLength left at its -1 sentinel). Framing is the Transport's
        // responsibility, so this is computed here, not carried on Response.
        case String():
          final bytes = utf8.encode(body);
          out.contentLength = bytes.length;
          out.add(bytes);
        case List<int>():
          out.contentLength = body.length;
          out.add(body);
        case Stream<List<int>>():
          await out.addStream(body);
      }
      await out.close();
    } catch (error, stack) {
      // Header/framing errors and mid-stream body failures land here. When a
      // stream body throws mid-write, dart:io has already marked the outgoing
      // as errored: close() then emits no terminating chunk and the connection
      // is destroyed, so the client sees a truncated response rather than one
      // framed as complete. Log rather than swallow, and still call close() to
      // release the connection.
      _onError(error, stack);
      try {
        await out.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> close({Duration grace = const Duration(seconds: 30)}) async {
    // Stop accepting, wait out in-flight requests within the grace window, then
    // force-close anything still lingering.
    final stopped = _server.close();
    // Before the grace clock starts, tell every in-flight request the
    // connection is going away. This fires each one's `closed` seam, which the
    // core wires to `ctx.abort()` — the same cooperative-cancellation signal a
    // client disconnect raises. A streaming handler that observes `c.aborted`
    // (an open SSE response) then ends its body at once, flushing a clean close
    // instead of being hard-truncated when the forced close lands; the request
    // leaves `_inFlight` promptly and the whole grace is not burned on it. A
    // handler that ignores the signal is unaffected and still gets its full
    // grace below. Iterate a snapshot: firing `closed` schedules the abort
    // asynchronously, which later removes the request from `_active`.
    for (final request in _active.toList()) {
      request.signalGoingAway();
    }
    if (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight).timeout(grace, onTimeout: () => const []);
    }
    // Open WebSocket connections are not "in-flight requests" — their handshake
    // already completed — so the drain above never waits on them. Send each a
    // 1001 "going away" and bound the wait: a peer that never acknowledges the
    // close must not hang shutdown, so after a short margin we stop waiting and
    // fall through to the forced server close, which destroys their sockets.
    if (_openSockets.isNotEmpty) {
      final closing = [
        for (final ws in _openSockets.toList())
          ws.close(WebSocketStatus.goingAway).catchError((_) {}),
      ];
      await Future.wait(
        closing,
      ).timeout(const Duration(seconds: 2), onTimeout: () => const []);
    }
    await _server.close(force: true).catchError((_) {});
    await stopped.catchError((_) {});
  }
}

/// Adapts a `dart:io` [WebSocket] to the transport-neutral [UpgradedChannel].
/// This is the only place `dart:io`'s WebSocket type is named on the server
/// path; everything above the transport sees the neutral value alone.
///
/// The raw socket is listened to *unconditionally* for the connection's whole
/// life — even when the handler never subscribes to [messages] (a push-only,
/// server-push handler, a path the interface advertises). That is load-bearing
/// for [done]: it must complete when the *peer* closes, and the only `dart:io`
/// signal that fires on a peer close is the data stream's `onDone` — not
/// `WebSocket.done`, which completes only on a *local* close (verified). Keeping
/// the subscription always-on lets that `onDone` reliably drive [done] — the
/// handler's disconnect signal and how the transport reclaims a closed socket
/// from its shutdown set — no matter whether the handler ever reads a frame.
///
/// What varies with a subscriber is only whether an inbound frame is
/// *forwarded* or *dropped*. The previous design re-presented every frame
/// through a single-subscription controller and gated backpressure on a
/// subscriber existing; a push-only handler (no [messages] listener) therefore
/// accumulated every inbound frame in that controller forever, with `onPause`
/// never firing (verified: 100k frames buffered, zero pauses). Here a frame is
/// enqueued only while a live [messages] subscriber wants it; with no
/// subscriber it is discarded (and counted, for the transport's own tests),
/// so a flood cannot grow memory without bound. Backpressure is still exact
/// while a subscriber exists: a slow consumer pauses the controller, which
/// pauses the raw socket read (real TCP backpressure), and resuming lifts both.
///
/// One consequence: a frame that arrives before the first [messages] listen is
/// dropped, not buffered. In practice a handler subscribes synchronously inside
/// its `onConnected` (which runs before any frame can be delivered), so a
/// normal handler loses nothing; only a genuinely push-only or late-listening
/// handler discards inbound frames, which is exactly its intent.
class _IoWebSocketChannel implements UpgradedChannel {
  _IoWebSocketChannel(this._ws) {
    _sub = _ws.listen(
      (dynamic message) {
        // Forward only while a live `messages` subscriber wants the frame; with
        // none (push-only handler, or one that cancelled), discard rather than
        // buffer in `_incoming`. `_dropped` makes the discard observable so the
        // "no unbounded buffering" property is testable.
        if (_subscribed) {
          // Data frames are `String` or `List<int>` — never null, so the cast
          // is total.
          _incoming.add(message as Object);
        } else {
          _dropped++;
        }
      },
      // An error with a subscriber is surfaced; with none there is no one to
      // deliver it to, so it is dropped like a data frame — `onDone` still
      // drives [done]. cancelOnError:false keeps the stream (and its onDone)
      // alive past a non-fatal error.
      onError: (Object e, StackTrace st) {
        if (_subscribed) _incoming.addError(e, st);
      },
      onDone: () {
        if (!_closed.isCompleted) _closed.complete();
        if (!_incoming.isClosed) _incoming.close();
      },
      cancelOnError: false,
    );
    _incoming.onListen = () {
      _subscribed = true;
    };
    // Backpressure, preserved only while a subscriber exists: a paused
    // controller pauses the raw socket read; resuming lifts both. With no
    // subscriber there is nothing to pause — frames are dropped, not queued.
    _incoming.onPause = _sub.pause;
    _incoming.onResume = _sub.resume;
    // The handler stopped listening: stop forwarding (drop from here on) but do
    // NOT cancel `_sub` — keeping the raw read alive is what lets a later peer
    // close still drive `onDone` → [done]. Cancelling would blind the transport
    // to that close and strand the socket in its shutdown set.
    _incoming.onCancel = () {
      _subscribed = false;
    };
  }
  final WebSocket _ws;
  final StreamController<Object> _incoming = StreamController<Object>();
  final Completer<void> _closed = Completer<void>();

  /// Whether a `messages` subscriber currently exists. Latched true on the
  /// first listen and back to false on cancel; frames are forwarded only while
  /// it holds, and discarded (into [_dropped]) otherwise.
  bool _subscribed = false;

  /// Count of inbound frames discarded because no subscriber wanted them — the
  /// testable witness that a push-only flood is dropped, not buffered.
  int _dropped = 0;

  // The subscription lives for the whole connection: its `onDone` closes the
  // controller and completes [done], and a local `close()` triggers that same
  // `onDone`, so it is always torn down without a manual cancel.
  // ignore: cancel_subscriptions
  late final StreamSubscription<dynamic> _sub;

  @override
  Stream<Object> get messages => _incoming.stream;

  @override
  void send(Object message) => _ws.add(message);

  @override
  Future<void> close([int? code, String? reason]) async {
    await _ws.close(code, reason);
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get done => _closed.future;
}

/// Test-only seam: builds the WebSocket channel adapter over [ws] and returns
/// its neutral [UpgradedChannel] face alongside a probe of how many inbound
/// frames it has *dropped* (frames that arrived while no `messages` subscriber
/// existed). It lets the transport's own tests assert that a push-only flood is
/// discarded rather than buffered without unbounded growth — the reported
/// defect — without exposing the private adapter type as API. Not exported from
/// `keta.dart`; reachable only via `package:keta/src/h1_transport.dart`.
(UpgradedChannel, int Function()) debugWebSocketChannel(WebSocket ws) {
  final channel = _IoWebSocketChannel(ws);
  return (channel, () => channel._dropped);
}

class _H1Request implements TransportRequest {
  _H1Request(this._request) {
    // Client-disconnect detection is only partial on dart:io's HttpServer:
    // while a request is handled it pauses the socket's read subscription
    // (http_impl.dart), so a client that drops the connection *after* the full
    // request is received and *before* the server writes cannot be observed —
    // there is no event until the next write attempt. Two signals are wired for
    // the cases that ARE observable:
    //  * response.done erroring — a write hitting the dropped socket (this
    //    reliably fires for streamed/large responses that overflow the socket
    //    buffer; a small buffered write to a just-closed loopback socket may
    //    still complete normally, so it is not a guarantee);
    //  * the request body erroring mid-receive — a client that drops while
    //    still sending its body (wired in [_trackedBody]).
    // The residual gap (idle disconnect during a no-write handler) is inherent
    // to dart:io's HttpServer and documented on `TransportRequest.closed`.
    _request.response.done.then(
      (_) {},
      onError: (Object _) {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }
  final HttpRequest _request;
  final Completer<void> _closed = Completer<void>();

  /// Fires the `closed` seam early, at graceful shutdown, so a cooperative
  /// in-flight handler can wind down within the grace instead of being
  /// hard-truncated by the forced close. It reuses `closed` — the
  /// transport-observed "the connection is going away" signal the core already
  /// routes to `ctx.abort()` — because at shutdown that is precisely the case:
  /// the connection is about to end. Idempotent, and harmless for a handler
  /// that never observes `aborted` (it simply runs on under the grace).
  void signalGoingAway() {
    if (!_closed.isCompleted) _closed.complete();
  }

  /// Whether the body stream has been listened to (dart:io latches
  /// `hasSubscriber` true on the first listen and never clears it).
  bool _bodyListened = false;

  /// Whether the body stream ran to completion — the whole declared body was
  /// received.
  bool _bodyFullyRead = false;

  @override
  Future<void> get closed => _closed.future;

  @override
  String get method => _request.method;

  @override
  Uri get uri => _request.uri;

  @override
  Stream<List<int>> get bodyStream => _body;

  /// Relays the raw body while recording whether it was fully received, with
  /// backpressure preserved. A mid-receive error is the client dropping the
  /// connection, so `closed` completes there too — the disconnect signal that
  /// dart:io *can* deliver. (An explicit subscription, not `yield*`, because
  /// `yield*` forwards the inner stream's errors straight past the generator's
  /// try/catch to the listener, leaving the drop unseen here.)
  late final Stream<List<int>> _body = _makeBody();

  Stream<List<int>> _makeBody() {
    final controller = StreamController<List<int>>();
    controller.onListen = () {
      _bodyListened = true;
      final sub = _request.listen(
        controller.add,
        onError: (Object e, StackTrace st) {
          if (!_closed.isCompleted) _closed.complete();
          controller.addError(e, st);
        },
        onDone: () {
          _bodyFullyRead = true;
          controller.close();
        },
      );
      controller
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = sub.cancel;
    };
    return controller.stream;
  }

  /// Whether the request declares a body worth defending against — a positive
  /// Content-Length or chunked transfer-encoding.
  bool get _bodyDeclared =>
      _request.contentLength > 0 || _request.headers.chunkedTransferEncoding;

  /// Called once the response is framed: if the handler never fully read a
  /// declared request body, refuse the connection so dart:io does not drain an
  /// unbounded upload and the dirty connection is not reused for keep-alive.
  ///
  /// dart:io auto-drains an unread body of any size at response completion, but
  /// skips that drain once the body has been listened to even once. So a body
  /// that was never touched is given a subscriber — paused, so not a byte is
  /// read — to latch the skip; a partially-read body already latched it.
  /// Cancelling instead of pausing would let dart:io treat the body as done and
  /// destroy the connection before the response is flushed, so the subscription
  /// is held (paused) until the non-persistent connection closes on its own.
  void severIfBodyUnread(HttpResponse out) {
    if (!_bodyDeclared || _bodyFullyRead) return;
    if (!_bodyListened) {
      // Listen (latching the drain-skip) and immediately pause: never a byte is
      // read, and the paused subscription stays alive — held by the incoming
      // stream — until the non-persistent connection closes on its own.
      // Cancelling instead would let dart:io treat the body as done and destroy
      // the connection before the response is flushed.
      // ignore: cancel_subscriptions
      _request.listen(null, cancelOnError: false).pause();
    }
    out.persistentConnection = false;
  }

  @override
  String get remoteAddress =>
      _request.connectionInfo?.remoteAddress.address ?? '';

  @override
  Map<String, List<String>> get headers {
    final result = <String, List<String>>{};
    _request.headers.forEach((name, values) {
      result[name.toLowerCase()] = values;
    });
    return result;
  }
}
