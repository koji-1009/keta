library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';
import 'response.dart';

/// A single Server-Sent Event, rendered onto the wire per the WHATWG HTML
/// "server-sent events" grammar (the `text/event-stream` format an
/// `EventSource` parses).
///
/// A value type, not a builder: like [SetCookie], the invariants are enforced
/// once at construction so an event that could *forge* the stream is
/// unrepresentable. An `event`/`id` carrying a CR or LF would open a second
/// field — or, with a blank line, dispatch a second event the caller never
/// wrote — which is the SSE analogue of header-injection/response-splitting.
/// Rejecting it here means every constructed [SseEvent] renders to exactly one
/// event, the same posture [Response] gives its header map.
final class SseEvent {
  /// Constructs and validates an event. Throws [ArgumentError] when [event] or
  /// [id] contains CR or LF, when [id] contains a NUL (U+0000), or when [retry]
  /// is negative.
  ///
  /// [data] is the only required field and MAY contain newlines: it is split
  /// into one `data:` line per segment at render time (see [toWire]), so a
  /// multi-line payload is represented faithfully rather than truncated. The
  /// other fields are single-line by construction — hence the checks.
  SseEvent(this.data, {this.event, this.id, this.retry}) {
    // A field that could smuggle a line break would forge events: a CR/LF in a
    // single-line field either starts a bogus field or (via a blank line) ends
    // the current event and begins another. Make that unrepresentable.
    if (event != null) _checkSingleLine(event!, 'event');
    if (id != null) {
      _checkSingleLine(id!, 'id');
      // The spec (last-event-ID processing) discards an id containing NUL
      // (U+0000). A silently-dropped id is a correctness trap for a caller
      // relying on reconnection; reject it at the source rather than ship a
      // field the client will throw away.
      if (id!.codeUnits.contains(0)) {
        throw ArgumentError.value(id, 'id', 'id must not contain NUL');
      }
    }
    // A negative retry renders as `retry: -N`, which the parser ignores (the
    // value is not all ASCII digits) — a silently-void field. Reject it so a
    // constructed retry is always one the client will honor.
    if (retry != null && retry!.isNegative) {
      throw ArgumentError.value(retry, 'retry', 'retry must not be negative');
    }
  }

  /// The event payload. May contain newlines (rendered as multiple `data:`
  /// lines). CR, LF, and CRLF are all normalized to LF on the wire — a bare CR
  /// can never leak into a `data:` line and break framing.
  final String data;

  /// The `event:` type field (the `EventSource` listener name), or null for the
  /// default `message` type. Single-line.
  final String? event;

  /// The `id:` field (becomes the connection's last-event-ID, echoed as
  /// `Last-Event-ID` on reconnect), or null. Single-line, no NUL.
  final String? id;

  /// The `retry:` reconnection hint, rendered as whole milliseconds, or null to
  /// leave the client's default in place. Non-negative.
  final Duration? retry;

  /// Renders this event as its `text/event-stream` text, terminated by the
  /// blank line that dispatches it.
  ///
  /// Field order is `event:`, `id:`, `retry:`, then one `data:` line per
  /// newline-split segment. Every field is written as `name: value` with a
  /// single space after the colon; the parser strips exactly one leading space,
  /// so a `data` value's own leading spaces round-trip intact (we always add
  /// one, the reader always removes one). `data` is split on CRLF/CR/LF alike,
  /// so no bare CR reaches the wire and the reader reconstructs the payload with
  /// LF joins.
  String toWire() {
    final b = StringBuffer();
    if (event != null) b.write('event: ${event!}\n');
    if (id != null) b.write('id: ${id!}\n');
    if (retry != null) b.write('retry: ${retry!.inMilliseconds}\n');
    // Split on any newline form so a multi-line payload becomes multiple
    // `data:` lines and CR/CRLF normalize to LF (SSE line-ending rules).
    for (final line in data.split(_newline)) {
      b.write('data: $line\n');
    }
    b.write('\n'); // the blank line that ends (dispatches) the event
    return b.toString();
  }

  /// This event's UTF-8 wire bytes — what actually flows down the response
  /// stream. Exposed so a caller assembling their own body has the exact
  /// encoding [Context.sse] uses.
  Uint8List encode() => utf8.encode(toWire());

  static final RegExp _newline = RegExp('\r\n|\r|\n');

  static void _checkSingleLine(String value, String field) {
    if (value.contains('\r') || value.contains('\n')) {
      throw ArgumentError.value(
        value,
        field,
        '$field must not contain CR or LF',
      );
    }
  }
}

/// A comment line (`:`-prefixed) sent as the keep-alive heartbeat. A comment is
/// ignored by the parser but is still traffic on the wire, so it resets the
/// idle timers of intermediary proxies that would otherwise cut a quiet stream.
const String _keepAliveComment = ': keep-alive\n\n';

/// The keep-alive comment's UTF-8 bytes, encoded once. The heartbeat text is
/// constant, so re-encoding it on every emission (potentially every few seconds
/// for the life of a long stream) is pure waste; every heartbeat writes this
/// single shared wire form.
final List<int> _keepAliveBytes = utf8.encode(_keepAliveComment);

/// The response-building surface for Server-Sent Events, added to [Context]
/// alongside `c.json`/`c.text` so an SSE endpoint reads the same as any other.
///
/// It is an extension method rather than a bare top-level function precisely so
/// it can see the request's [Context.aborted]: a timeout or client disconnect
/// then cooperatively ends the stream instead of leaving the source producing
/// into a socket no one is reading (a requirement of the E-11 design).
extension SseResponses<E> on Context<E> {
  /// Builds a `200 text/event-stream` [Response] whose body is [events]
  /// rendered to the SSE wire format.
  ///
  /// The result is an ordinary [Response] with a `Stream<List<int>>` body — no
  /// new transport machinery: the HTTP/1.1 transport already frames a stream
  /// body as chunked, and `gzip()`/`etag()` already pass stream bodies through
  /// untouched, so SSE composes with the existing model unchanged.
  ///
  /// Headers are `content-type: text/event-stream; charset=utf-8` and
  /// `cache-control: no-cache`; [headers] merge over (and may override) those.
  ///
  /// [keepAlive] is opt-in (null by default): when set, a `: keep-alive`
  /// comment is emitted whenever no event has been sent for that duration,
  /// keeping proxy idle timers from cutting a quiet stream. It is opt-in rather
  /// than a hidden default because the right interval depends on the deployment
  /// (the proxy's idle timeout), and keta does not start background timers the
  /// caller did not ask for. When null, no timer is ever created — nothing can
  /// pin the isolate.
  ///
  /// [maxIdle] and [maxLifetime] are opt-in lifetime bounds (E-21a): `timeout()`
  /// only bounds time-to-*first*-byte, so once a stream starts, a long-lived SSE
  /// connection otherwise has no self-defense against a dead or abandoned peer.
  /// Both are null (no bound, current behavior unchanged) by default, for the
  /// same reason [keepAlive] is — keta never starts a timer the caller did not
  /// ask for.
  ///
  /// [maxIdle] fires when no *application* event (one delivered from [events])
  /// has gone out for that long. A `keepAlive` comment deliberately does NOT
  /// reset this clock: it is server-originated filler, not evidence the app is
  /// still producing, so if it did reset the clock, `maxIdle` could never fire
  /// on exactly the case it exists to catch — an app that has stopped feeding
  /// the stream while the connection is nominally still open. The two options
  /// compose rather than conflict: `keepAlive` stops an intermediary from
  /// killing a quiet-but-alive stream; `maxIdle` reaps a stream the app itself
  /// has abandoned.
  ///
  /// A resume also re-arms a *fresh, full* `maxIdle` window (not the remainder
  /// of the one a pause interrupted) — see `armIdle`'s call from `onResume`.
  /// That is a deliberate choice, not an oversight: `maxIdle` is meant to
  /// reap an abandoned *application*, and a consumer that is merely slow —
  /// paused under backpressure, then resuming — is not that; punishing it
  /// with a clock that kept running while paused would cut a live-but-slow
  /// reader for a fault that is the network's, not the app's. The tradeoff
  /// this accepts: a peer that paces its own pause/resume can keep
  /// re-arming `maxIdle` indefinitely, even after the app has genuinely gone
  /// silent, so `maxIdle` alone cannot be relied on to bound such a client.
  /// [maxLifetime] is the bound that holds regardless — it is never re-armed
  /// by activity, pause, or resume (see its own doc below), so it is the cap
  /// to depend on against a pathological pause/resume client.
  ///
  /// [maxLifetime] is an absolute cap measured from when the response starts
  /// streaming, regardless of activity — it fires even if events (or
  /// keep-alives) are still flowing right up to the deadline, and it fires even
  /// while the body is paused under backpressure (a slow or dead reader whose
  /// full socket buffer has paused the body subscription). On firing it frees the
  /// [events] subscription and every timer at once, so under sustained
  /// backpressure neither the source nor a timer can outlive the deadline. One
  /// honest caveat: the chunked terminator is a byte on the wire, so it is
  /// buffered behind the paused consumer and the socket's final release still
  /// waits on the transport resuming or the OS reporting the dead peer — but
  /// nothing keeps producing, and no timer pins the isolate, in the meantime.
  ///
  /// Either duration, if given, must be positive; a non-positive [maxIdle] or
  /// [maxLifetime] is an authoring defect and throws [ArgumentError]
  /// immediately, the same posture [SseEvent]'s constructor takes for a
  /// malformed field.
  ///
  /// On expiry (either bound), the stream ends the same way a client disconnect
  /// or server shutdown does — the body controller is closed normally, so the
  /// chunked response ends on a clean boundary (never mid-event) — and the source
  /// subscription and every timer are freed through one shared, once-guarded
  /// teardown. That teardown runs directly on expiry rather than only through the
  /// controller's `onCancel`, because a `close()` whose consumer is paused under
  /// backpressure defers `onCancel` until a resume a dead client may never
  /// perform; driving teardown directly keeps `maxLifetime` an honest cap in
  /// exactly that case. The single guard means the two entry points — a real
  /// cancel and an expiry — never tear down twice.
  ///
  /// Lifecycle: the [events] subscription and every timer ([keepAlive],
  /// [maxIdle], [maxLifetime]) are torn down when the stream completes, errors,
  /// the client disconnects (the transport cancels the body subscription on a
  /// failed write), the request aborts ([aborted]), or a bound expires —
  /// whichever comes first. None outlives the response.
  Response sse(
    Stream<SseEvent> events, {
    Duration? keepAlive,
    Duration? maxIdle,
    Duration? maxLifetime,
    Map<String, List<String>>? headers,
  }) {
    if (maxIdle != null && maxIdle <= Duration.zero) {
      throw ArgumentError.value(maxIdle, 'maxIdle', 'maxIdle must be positive');
    }
    if (maxLifetime != null && maxLifetime <= Duration.zero) {
      throw ArgumentError.value(
        maxLifetime,
        'maxLifetime',
        'maxLifetime must be positive',
      );
    }
    return Response(
      200,
      headers: {
        'content-type': const ['text/event-stream; charset=utf-8'],
        'cache-control': const ['no-cache'],
        ...?headers,
      },
      body: _sseBody(events, keepAlive, maxIdle, maxLifetime, aborted),
    );
  }
}

/// Wraps [events] into the byte stream the transport writes, owning the
/// keep-alive, [maxIdle], and [maxLifetime] timers and guaranteeing teardown of
/// all three and the source subscription.
///
/// A [StreamController] with explicit `onCancel`, not an `async*` generator:
/// only the controller gives a single, deterministic cleanup point that fires
/// on the transport's cancel (a failed write to a disconnected client cancels
/// the body subscription) — the exact seam `_H1Request._makeBody` relies on.
/// An `async*` body cannot host a periodic keep-alive timer nor cancel it
/// synchronously on that signal, so the timer could outlive the request and
/// pin the isolate (the discipline `StdoutLog.dispose` enforces for its timer).
Stream<List<int>> _sseBody(
  Stream<SseEvent> events,
  Duration? keepAlive,
  Duration? maxIdle,
  Duration? maxLifetime,
  Future<void> aborted,
) {
  late final StreamController<List<int>> controller;
  StreamSubscription<SseEvent>? sub;
  Timer? keepAliveTimer;
  Timer? idleTimer;
  Timer? lifetimeTimer;

  // The isolate-liveness cleanup: cancel the source subscription and every
  // timer. Guarded to run exactly once so it is safe to drive from more than one
  // place — `onCancel` (the transport's cancel seam) and `endStream` (every
  // expiry/abort/completion) both route through it, and whichever reaches it
  // second is a no-op. That once-guard is what preserves the "source `onCancel`
  // fires exactly once" guarantee the no-double-teardown race tests pin.
  var tornDown = false;
  Future<void>? teardown() {
    if (tornDown) return null;
    tornDown = true;
    keepAliveTimer?.cancel();
    idleTimer?.cancel();
    lifetimeTimer?.cancel();
    return sub?.cancel();
  }

  // THE single end path for every form of stream end — normal completion,
  // source error, client disconnect/abort/shutdown, and a `maxIdle`/`maxLifetime`
  // expiry. Two things happen here, and BOTH matter:
  //
  //  1. `controller.close()` ends the transport-facing byte stream so the
  //     chunked response terminates on a clean boundary (a proper terminator,
  //     never a mid-event cut).
  //  2. `teardown()` frees the source subscription and every timer *directly*.
  //
  // Step 2 cannot be left to `close()` alone: when the consumer is paused
  // (backpressure — a slow or dead client whose socket write buffer is full,
  // which dart:io signals by pausing this body's subscription), `close()` defers
  // both its `done` delivery and the `onCancel` that would otherwise run
  // teardown until the consumer resumes — which a dead client may never do.
  // `maxLifetime` is precisely the bound that must still fire in that state, so
  // it drives teardown here rather than waiting on a resume that never comes. The
  // socket itself is not released until the consumer resumes or TCP errors (the
  // buffered `done` stays behind the paused consumer), but no timer and no source
  // subscription outlives the expiry. The `isClosed`/`tornDown` guards make this
  // safe to call from several signals racing on the same tick (e.g. `maxIdle`
  // firing the same tick the source also completes).
  void endStream() {
    if (!controller.isClosed) controller.close();
    unawaited(teardown() ?? Future<void>.value());
  }

  // A single-shot timer re-armed after every emission gives precise "no event
  // for `keepAlive`" semantics: each event resets the heartbeat clock, and a
  // purely idle stream heartbeats exactly every `keepAlive`.
  void armKeepAlive() {
    if (keepAlive == null) return;
    keepAliveTimer?.cancel();
    keepAliveTimer = Timer(keepAlive, () {
      if (controller.isClosed || controller.isPaused) return;
      controller.add(_keepAliveBytes);
      armKeepAlive();
      // Deliberately does NOT touch `idleTimer`: a keep-alive comment is
      // server-originated filler, not an application event, so it must never
      // reset `maxIdle`'s clock — see the doc on `SseResponses.sse`.
    });
  }

  // Re-armed on a real event going out (never by a keep-alive — see
  // armKeepAlive) and, separately, on every resume (see onResume below) with a
  // fresh full window rather than the pause-interrupted remainder. So this
  // measures true application silence only while the consumer isn't pausing;
  // a consumer that paces its own pause/resume can keep this from ever
  // firing. That is a deliberate tradeoff, not a gap — see the doc on
  // [SseResponses.sse]'s `maxIdle` parameter for why, and why `maxLifetime`
  // is the bound to rely on against such a client.
  void armIdle() {
    if (maxIdle == null) return;
    idleTimer?.cancel();
    idleTimer = Timer(maxIdle, endStream);
  }

  controller = StreamController<List<int>>(
    onListen: () {
      armKeepAlive();
      armIdle();
      // A one-shot absolute cap from stream start: never re-armed by activity
      // (unlike `keepAlive`/`maxIdle`) and never paused/resumed with the
      // subscription below — it is a wall-clock bound, not an activity one.
      if (maxLifetime != null) {
        lifetimeTimer = Timer(maxLifetime, endStream);
      }
      sub = events.listen(
        (event) {
          if (controller.isClosed) return;
          controller.add(event.encode());
          armKeepAlive();
          armIdle(); // a real event just went out — reset the idle clock
        },
        onError: (Object e, StackTrace st) {
          // Surface the source error to the transport (which destroys the
          // connection, truncating the response) and stop: no more heartbeats,
          // and close so `onCancel` runs the single teardown path.
          keepAliveTimer?.cancel();
          idleTimer?.cancel();
          lifetimeTimer?.cancel();
          if (!controller.isClosed) {
            controller.addError(e, st);
            controller.close();
          }
        },
        onDone: () {
          keepAliveTimer?.cancel();
          idleTimer?.cancel();
          lifetimeTimer?.cancel();
          endStream();
        },
      );
      // Cooperative cancellation: a timeout, a client disconnect, or a server
      // shutdown (which fires the request's `closed`) completes `aborted`,
      // which ends the stream so the source stops producing into a dead — or
      // soon-to-be-closed — socket. Closing the controller *normally* here is
      // what makes shutdown clean: the transport's `addStream` completes and it
      // frames the chunked body to a proper end (a `0\r\n\r\n` terminator via
      // its ordinary `close()`), so an open SSE response winds down on a whole
      // event boundary instead of being cut mid-event by the forced socket
      // close. Closing here also triggers `onCancel`, which cancels the source
      // subscription. No extra byte is emitted: the wire ends exactly on the
      // last event the source produced, the invariant the abort tests pin.
      unawaited(aborted.then((_) => endStream()));
    },
    // THE transport cancel seam. Fires on an explicit listener cancel (the
    // transport's failed-write path) and after a normal close (done delivery
    // auto-cancels the subscription). Routes through the shared once-guarded
    // `teardown`, so a cancel that arrives after an expiry already tore down is
    // a no-op, and one that arrives first frees every timer (including
    // `lifetimeTimer`, which nothing else above touches) and the source
    // subscription — nothing outlives the connection either way.
    onCancel: teardown,
    // Preserve backpressure: when the transport pauses the body, stop pulling
    // the source and hold off the keep-alive and idle clocks; resume all three
    // together. A heartbeat added while paused would defeat the pause, and a
    // paused stream isn't producing anyway, so pausing must not by itself run
    // `maxIdle` out — that would punish a slow *reader*, not an idle *app*.
    // `maxLifetime` is deliberately left running through a pause: it is an
    // absolute cap "regardless of activity", and backpressure is exactly
    // activity, just held back. When it fires while paused, `endStream` frees the
    // source and timers directly (its `teardown`), not via this paused
    // subscription's deferred `onCancel` — the cap holds even against a reader
    // that never resumes.
    onPause: () {
      keepAliveTimer?.cancel();
      idleTimer?.cancel();
      sub?.pause();
    },
    onResume: () {
      sub?.resume();
      armKeepAlive();
      armIdle();
    },
  );

  return controller.stream;
}
