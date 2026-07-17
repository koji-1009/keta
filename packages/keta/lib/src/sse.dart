library;

import 'dart:async';
import 'dart:convert';

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
  List<int> encode() => utf8.encode(toWire());

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
  /// Lifecycle: the [events] subscription and the keep-alive timer are torn
  /// down when the stream completes, errors, the client disconnects (the
  /// transport cancels the body subscription on a failed write), or the request
  /// aborts ([aborted]) — whichever comes first. None outlives the response.
  Response sse(
    Stream<SseEvent> events, {
    Duration? keepAlive,
    Map<String, List<String>>? headers,
  }) => Response(
    200,
    headers: {
      'content-type': const ['text/event-stream; charset=utf-8'],
      'cache-control': const ['no-cache'],
      ...?headers,
    },
    body: _sseBody(events, keepAlive, aborted),
  );
}

/// Wraps [events] into the byte stream the transport writes, owning the
/// keep-alive timer and guaranteeing teardown of both it and the source
/// subscription.
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
  Future<void> aborted,
) {
  late final StreamController<List<int>> controller;
  StreamSubscription<SseEvent>? sub;
  Timer? timer;

  void cancelTimer() {
    timer?.cancel();
    timer = null;
  }

  // A single-shot timer re-armed after every emission gives precise "no event
  // for `keepAlive`" semantics: each event resets the idle clock, and a purely
  // idle stream heartbeats exactly every `keepAlive`.
  void armKeepAlive() {
    if (keepAlive == null) return;
    timer?.cancel();
    timer = Timer(keepAlive, () {
      if (controller.isClosed || controller.isPaused) return;
      controller.add(utf8.encode(_keepAliveComment));
      armKeepAlive();
    });
  }

  controller = StreamController<List<int>>(
    onListen: () {
      armKeepAlive();
      sub = events.listen(
        (event) {
          if (controller.isClosed) return;
          controller.add(event.encode());
          armKeepAlive(); // an event just went out — reset the idle clock
        },
        onError: (Object e, StackTrace st) {
          // Surface the source error to the transport (which destroys the
          // connection, truncating the response) and stop: no more heartbeats,
          // and close so `onCancel` runs the single teardown path.
          cancelTimer();
          if (!controller.isClosed) {
            controller.addError(e, st);
            controller.close();
          }
        },
        onDone: () {
          cancelTimer();
          if (!controller.isClosed) controller.close();
        },
      );
      // Cooperative cancellation: a timeout or disconnect completes `aborted`,
      // which ends the stream so the source stops producing into a dead socket.
      // Closing here triggers `onCancel`, which cancels the source subscription.
      unawaited(
        aborted.then((_) {
          if (!controller.isClosed) controller.close();
        }),
      );
    },
    // THE cleanup seam. Fires on an explicit listener cancel (the transport's
    // failed-write path) and after a normal close (done delivery auto-cancels
    // the subscription). Idempotent: cancelling a spent subscription is a no-op.
    onCancel: () {
      cancelTimer();
      return sub?.cancel();
    },
    // Preserve backpressure: when the transport pauses the body, stop pulling
    // the source and hold off heartbeats; resume both together. A heartbeat
    // added while paused would defeat the pause, so it waits for the resume.
    onPause: () {
      cancelTimer();
      sub?.pause();
    },
    onResume: () {
      sub?.resume();
      armKeepAlive();
    },
  );

  return controller.stream;
}
