library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HeaderValue, HttpException;
import 'dart:typed_data';

import 'package:keta/keta.dart';
import 'package:mime/mime.dart';

/// Byte and count ceilings for a multipart request. `App.maxBodyBytes` does NOT
/// apply here — reception rides the deliberate `c.bodyStream()` escape, so this
/// layer owns the limits. An oversized body or part raises [PayloadTooLarge]
/// (413); a part-count flood raises [BadRequest] (400, see [maxParts]).
class const MultipartLimits({
  /// Cap on the whole request body, enforced while streaming. Bytes in parts
  /// the consumer skips still count here — they are drained through the same
  /// meter (see [parts]) — so an attacker cannot hide payload in unread parts.
  final int maxTotalBytes = 8 * 1024 * 1024,

  /// Cap on a single part, enforced on every read path — [Part.bytes],
  /// [Part.text], AND the unbuffered [Part.stream] — as [PayloadTooLarge].
  final int maxPartBytes = 1024 * 1024,

  /// Cap on the number of parts, a flood-DoS guard. A part-count flood is a
  /// malformed/abusive request rather than an oversized payload, so exceeding
  /// this raises [BadRequest] (400), not [PayloadTooLarge] (413).
  final int maxParts = 64,
});

/// One part of a multipart body. The [stream] is the deliberate unbuffered path
/// (persist a large upload without holding it in memory); [bytes]/[text] are the
/// buffered readers. Every path is bounded by `MultipartLimits.maxPartBytes` —
/// the API owns the size limit, the caller never has to.
///
/// A part's body may be *requested* at most once, via exactly one of
/// [stream], [bytes], or [text]; a second request throws [StateError] (the
/// backing MIME stream is single-subscription). Requesting is not the same as
/// reading, though: [stream] hands back a lazy `Stream` that does nothing
/// until listened to, so a caller can request it and then advance the outer
/// `Stream<Part>` without ever subscribing. [parts] treats that exactly like
/// never having requested the body at all — it drains the part for the
/// caller (charged to `maxTotalBytes`) the moment it advances past it,
/// whether the body was untouched or merely claimed-but-unlistened. So: read
/// eagerly, or not at all — a stream stashed away to listen to "later"
/// (after the loop has moved on) does NOT quietly see an already-drained
/// source and yield nothing: the drain already subscribed to the
/// single-subscription source out from under it, so the late `.listen()`
/// instead surfaces a `StateError` ('Stream has already been listened to')
/// as an error event, followed by done. Either way, consumption (in order,
/// out of order, or skipped outright) can neither deadlock nor smuggle
/// uncounted bytes.
class Part._(final _RawPart _raw, final int _maxBytes) {
  /// Whether the body has been claimed — requested via [stream]/[bytes]/[text],
  /// or already drained by [parts]. Guards against a second request; does NOT
  /// by itself mean the body was actually consumed (see [_listened]).
  bool _taken = false;

  /// Whether the stream returned by [stream] was actually listened to. Set
  /// from inside the lazy `async*` body in [_limitPart], which only starts
  /// running once something subscribes — so this flag distinguishes "grabbed
  /// `.stream` but never listened" (still needs draining) from "listened, in
  /// progress or finished" (already being handled by its own listener).
  bool _listened = false;

  /// The part's headers, lower-cased by the MIME parser.
  Map<String, String> get headers => _raw.headers;

  /// The `name` of the form field, or null.
  String? get name => _disposition('name');

  /// The `filename` for a file part, or null for a plain field.
  ///
  /// Entirely client-supplied and never sanitized here: it may be `../../etc/
  /// passwd`, an absolute path, a Windows path, a name that is only control
  /// characters, or megabytes long. Using it to build a path — `File('uploads/
  /// ${part.filename}')` — is a traversal write primitive. Treat it as a display
  /// label; derive the storage name yourself (a generated id, or a hard
  /// allowlist), and keep this value only as metadata beside it. keta does not
  /// sanitize it because what a safe name is depends on the store it is going
  /// to, and a sanitizer that guessed would be trusted for more than it can
  /// deliver.
  String? get filename => _disposition('filename');

  /// Memoized result of parsing `content-disposition`, computed at most once
  /// per part. A real consumer typically reads [name] and [filename] (and
  /// sometimes both, more than once) off the same part, and the header string
  /// never changes underneath it — `HeaderValue.parse` is a pure function of
  /// that string — so re-tokenizing the full RFC 2183 quoted-string grammar
  /// on every access is pure waste. `null` here means either "not parsed
  /// yet" or "parsed and failed"; [_dispositionParsed] disambiguates those
  /// two so a malformed header (which legitimately parses to nothing) is
  /// also cached rather than re-thrown-and-caught on every read.
  Map<String, String?>? _dispositionParams;
  bool _dispositionParsed = false;

  /// The raw part body, unbuffered, but still bounded: the returned stream
  /// throws [PayloadTooLarge] the moment cumulative bytes exceed `maxPartBytes`.
  /// A caller that legitimately needs more must raise `maxPartBytes` — the limit
  /// is never silently bypassed on this path.
  Stream<List<int>> get stream {
    _claim();
    return _limitPart(_raw.body);
  }

  /// The part body buffered into bytes, failing with [PayloadTooLarge] past
  /// `maxPartBytes`. Typed [Uint8List] deliberately — the buffer is contiguous
  /// bytes, and the concrete static type lets an AOT-compiled consumer loop
  /// read it unboxed (the same judgment as `Context.bodyBytes`).
  Future<Uint8List> bytes() async {
    final builder = BytesBuilder(copy: false);
    // Route through [stream] so the per-part limit lives in exactly one place.
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// The part body decoded as UTF-8 (subject to the same per-part limit).
  Future<String> text() async => utf8.decode(await bytes());

  /// Marks the body as consumed, rejecting a second read of the
  /// single-subscription MIME stream with a diagnostic instead of an opaque
  /// "already listened" [StateError] from deep in the stream machinery.
  void _claim() {
    if (_taken) {
      throw StateError('multipart part body already consumed');
    }
    _taken = true;
  }

  /// Drains an unread body when the consumer advances past it. Runs whether
  /// the part was never touched OR was claimed via [stream] but never
  /// listened — [_listened] is what tells those two apart from "a listener is
  /// already consuming (or has consumed) it", not [_taken] alone: `.stream`
  /// sets `_taken` synchronously on request, well before anything actually
  /// subscribes, so relying on `_taken` here would treat a claimed-but-dropped
  /// stream as already handled and never drain it — exactly the hang this
  /// guards against (the MIME parser only surfaces the next part once the
  /// current body is consumed). Draining the raw `_source` directly (not
  /// through [stream]) deliberately skips the per-part cap: a drained part is
  /// not an error, but its bytes must still flow through the total meter
  /// upstream in [parts], so they cannot be used to smuggle payload past
  /// `maxTotalBytes`. A no-op once the body is actually being (or has been)
  /// listened to.
  Future<void> _drainIfUnread() async {
    if (_listened) return;
    _taken = true;
    await _raw.body.drain<void>();
  }

  /// Wraps a body stream so cumulative bytes past `maxPartBytes` abort with
  /// [PayloadTooLarge] rather than being buffered or forwarded. `async*`
  /// bodies are lazy — nothing below this line runs until the returned stream
  /// is listened to — so marking [_listened] as the first statement means it
  /// flips exactly when a subscriber starts consuming, not merely when
  /// [stream] was called.
  Stream<List<int>> _limitPart(Stream<List<int>> source) async* {
    _listened = true;
    var total = 0;
    await for (final chunk in source) {
      total += chunk.length;
      if (total > _maxBytes) {
        throw PayloadTooLarge('multipart part exceeds $_maxBytes bytes');
      }
      yield chunk;
    }
  }

  String? _disposition(String key) {
    if (!_dispositionParsed) {
      _dispositionParsed = true;
      final value = _raw.headers['content-disposition'];
      if (value != null) {
        try {
          // `HeaderValue.parse` implements the RFC 2183 / 6266 quoted-string
          // rules that a regex cannot: backslash-escaped quotes inside a
          // quoted value (`filename="a\"b"`), bare unquoted tokens (legal,
          // emitted by non-browser clients), and case-insensitive parameter
          // names (all lower-cased). RFC 5987 extended values (`filename*=`)
          // stay unsupported by design — they land under the distinct key
          // `filename*`, so a percent-encoded name reads as absent here
          // rather than being mis-decoded.
          _dispositionParams = HeaderValue.parse(value).parameters;
        } on HttpException {
          // A malformed header (e.g. an unterminated quote) yields no
          // parameters rather than tearing down the whole part stream from a
          // synchronous getter. Cached as such — every later read of [name]
          // or [filename] degrades to null again, without re-parsing.
          _dispositionParams = null;
        }
      }
    }
    return _dispositionParams?[key];
  }
}

/// Parses [c]'s `multipart/form-data` body into a stream of [Part]s, delegating
/// boundary parsing to package:mime. A non-multipart request (or a missing
/// boundary) is a [BadRequest]; an oversized body or part is a [PayloadTooLarge];
/// a part-count flood is a [BadRequest]. A body the parser cannot frame at all —
/// a malformed part header, a bad boundary terminator, a truncated upload — is
/// also a [BadRequest], never an escaped error: see [_GuardedMultipart] for why
/// that takes a zone.
///
/// Parts need not be read in order or at all: when the consumer advances, a
/// part's body is drained for it — charged to `maxTotalBytes` — unless it is
/// actively (or already) being listened to, whether the part was left
/// completely untouched or its [Part.stream] was requested and then dropped
/// without a listener. Either way, a skipped part can neither deadlock the
/// underlying single-subscription MIME stream nor hide uncounted bytes.
Stream<Part> parts<E>(
  Context<E> c, {
  MultipartLimits limits = const MultipartLimits(),
}) async* {
  final contentType = c.header('content-type') ?? '';
  if (!_isMultipartFormData(contentType)) {
    throw const BadRequest('expected a multipart/form-data body');
  }
  final boundary = _boundary(contentType);
  if (boundary == null) {
    throw const BadRequest('multipart request is missing its boundary');
  }

  final guard = _GuardedMultipart(
    _limitTotal(c.bodyStream(), limits.maxTotalBytes),
    boundary,
    c.aborted,
  );
  var count = 0;
  try {
    await for (final raw in guard.stream) {
      if (++count > limits.maxParts) {
        throw BadRequest('multipart exceeds ${limits.maxParts} parts');
      }
      final part = Part._(raw, limits.maxPartBytes);
      yield part;
      // The consumer has finished with this part (its loop body ran to the
      // point of requesting the next element). Drain anything not actively
      // being listened to: the MIME parser only surfaces the next part once the
      // current body is consumed, and draining routes those bytes through
      // `_limitTotal` above so they count toward the total. This covers both an
      // untouched part AND one whose `.stream` was requested but never
      // listened — `Part._drainIfUnread` checks `_listened`, not merely
      // whether the body was requested, so a claim without a subscriber cannot
      // stall this loop waiting for a listener that never comes.
      await part._drainIfUnread();
    }
  } finally {
    // Covers every way this generator can stop early — the consumer breaking
    // out of its loop, a `maxParts` throw, a cancelled response — so the
    // parser never keeps reading a body nobody will collect.
    await guard.close();
  }
}

/// One part as it leaves the parser: the headers it carried, and a body stream
/// that a fatal parse failure can terminate (which the parser's own per-part
/// stream cannot — see [_GuardedMultipart]).
class _RawPart(final Map<String, String> headers, final Stream<List<int>> body);

/// Runs package:mime's multipart parser with its failures contained.
///
/// The parser reports a frame it cannot parse by throwing SYNCHRONOUSLY from
/// the source subscription's `onData`. That throw never reaches the stream the
/// parser produces — it goes to the zone that registered the callback, which
/// for a plain `transform` is the root zone, where it is an unhandled error
/// that terminates the isolate. `recover()` cannot see it (it is not on any
/// future the handler awaits) and neither can the transport's defensive catch.
/// Without the zone below, one unauthenticated POST carrying a malformed part
/// header takes the server down — under `serve(isolates: n)`, one worker at a
/// time and silently, until it reaches the one whose death ends the process.
///
/// Registering the subscription inside a guarded zone routes that throw here
/// instead, where it becomes an ordinary stream error — a [BadRequest], since a
/// body the parser cannot frame is a malformed request, not a server fault.
///
/// The second half of the containment is the in-flight part. When the parser
/// dies mid-part it abandons that part's body controller without closing it, so
/// a consumer awaiting `part.text()` waits forever. Each body is therefore
/// handed out wrapped, and the same failure that ends the part stream also
/// errors whichever body is being read.
///
/// The third piece — the one a parse error alone does not cover — is the peer
/// that stops sending. A client that opens an upload, sends half a part, and
/// walks away produces NO event at all: dart:io leaves the request body stream
/// stalled rather than erroring it, so the parser never advances and never
/// fails, and the handler holds its request slot until the process restarts.
/// [aborted] (`c.aborted`, which a disconnect, a `timeout()`, or a graceful
/// shutdown completes) is the only signal that arrives in that case, so it is
/// wired in as a failure like any other. This is the cooperative-cancellation
/// contract, honoured on the framework's side of the seam rather than left to
/// every upload handler to remember.
class _GuardedMultipart(
  Stream<List<int>> source,
  String boundary,
  Future<void> aborted,
) {
  this {
    _out = StreamController<_RawPart>(
      onListen: () => _start(source, boundary),
      onPause: () => _sub?.pause(),
      onResume: () => _sub?.resume(),
      onCancel: () => _sub?.cancel(),
    );
    // Guarded inside `_fail`, so an abort that arrives after the body was fully
    // read — the common case, since `aborted` also completes at shutdown — is a
    // no-op rather than a late error on a finished request.
    unawaited(
      aborted.then(
        (_) => _fail(
          const BadRequest('multipart body ended before the final boundary'),
        ),
      ),
    );
  }

  late final StreamController<_RawPart> _out;
  StreamSubscription<MimeMultipart>? _sub;

  /// The first failure that escaped the parser, held as a VALUE rather than as
  /// an error: a body that is never read must not raise an unhandled error of
  /// its own just because this completer was completed.
  final _fatal = Completer<Object>();

  Stream<_RawPart> get stream => _out.stream;

  void _start(Stream<List<int>> source, String boundary) {
    runZonedGuarded(() {
      _sub = source
          .transform(MimeMultipartTransformer(boundary))
          .listen(
            (mime) {
              // Same race as inside `_guardBody`: a failure may already have
              // closed this stream while the parser still has a part to hand
              // over. Dropping it is right — the consumer has been told the
              // body is unusable.
              if (_out.isClosed) return;
              _out.add(_RawPart(mime.headers, _guardBody(mime)));
            },
            // An asynchronous error — `_limitTotal`'s PayloadTooLarge, a
            // transport read failure — arrives here as an ordinary event. It
            // still goes through `_fail` so an in-flight body is terminated
            // with it rather than left hanging.
            onError: _fail,
            onDone: () {
              if (!_out.isClosed) _out.close();
            },
          );
    }, (error, _) => _fail(error));
  }

  /// Ends the part stream, and any body currently being read, with [error].
  /// A [KetaException] passes through with its own status (`_limitTotal`'s 413
  /// stays a 413); anything else came from the parser rejecting the bytes, and
  /// is the client's fault.
  void _fail(Object error) {
    final translated = error is KetaException
        ? error
        : BadRequest('malformed multipart body: $error');
    if (!_fatal.isCompleted) {
      _fatal.complete(translated);
    }
    if (!_out.isClosed) {
      _out
        ..addError(translated)
        ..close();
    }
    // The parser is past saving; stop pulling bytes into it. Scheduled rather
    // than immediate because `_fail` runs from inside the subscription's own
    // dispatch when the throw was synchronous.
    unawaited(Future.microtask(() => _sub?.cancel()).catchError((_) {}));
  }

  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
    await _sub?.cancel();
  }

  /// Wraps one part body so [_fail] can terminate it. Pause, resume, and cancel
  /// are forwarded 1:1 to the parser's own body subscription, which is what
  /// keeps the parser's backpressure dance intact: it only advances to the next
  /// part once the current body is consumed, and it resumes the source when a
  /// body has demand even while the part stream itself is paused.
  Stream<List<int>> _guardBody(Stream<List<int>> body) {
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? sub;
    // Every write goes through these. Terminating a body on a fatal failure
    // races the parser, which may already have another chunk in hand for the
    // part it is about to abandon: the source and this controller are closed by
    // two different events, and an ungated `add` after the close is an
    // "add event after closing" thrown into the isolate — the very shape of
    // failure this class exists to prevent.
    void emit(List<int> chunk) {
      if (!out.isClosed) out.add(chunk);
    }

    void finish(Object error) {
      if (out.isClosed) return;
      out
        ..addError(error)
        ..close();
      // The part is over; stop the parser pushing into a dead controller.
      unawaited(Future.sync(() => sub?.cancel()).catchError((_) {}));
    }

    out = StreamController<List<int>>(
      onListen: () {
        sub = body.listen(
          emit,
          onError: finish,
          onDone: () {
            if (!out.isClosed) out.close();
          },
        );
        unawaited(_fatal.future.then(finish));
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }
}

/// Whether [contentType]'s media type is exactly `multipart/form-data`
/// (case-insensitively), parsed rather than string-matched: a `startsWith`
/// check also accepts an unrelated type that merely shares the prefix, like
/// `multipart/form-data-x` or `multipart/form-dataphoto`. Uses the same
/// `HeaderValue` parser as the boundary and disposition parameters below, so
/// a trailing `; boundary=...` (or any other parameter) never confuses the
/// comparison the way a naive substring check might. A malformed header
/// parses to a value that simply isn't `multipart/form-data` here — `false`,
/// not a thrown exception — consistent with how `_boundary` treats the same
/// input.
bool _isMultipartFormData(String contentType) {
  try {
    return HeaderValue.parse(contentType).value.toLowerCase() ==
        'multipart/form-data';
  } on HttpException {
    return false;
  }
}

String? _boundary(String contentType) {
  try {
    // The same RFC-compliant parser as the disposition parameters: it keeps a
    // quoted boundary that itself contains ';' intact (`boundary="a;b"`, legal
    // per RFC 2046), which a naive `split(';')` would mangle, and honors a
    // case-insensitive `Boundary=` parameter name.
    final value = HeaderValue.parse(contentType).parameters['boundary'];
    return (value == null || value.isEmpty) ? null : value;
  } on HttpException {
    return null;
  }
}

Stream<List<int>> _limitTotal(Stream<List<int>> source, int maxBytes) async* {
  var total = 0;
  await for (final chunk in source) {
    total += chunk.length;
    if (total > maxBytes) {
      throw PayloadTooLarge('multipart body exceeds $maxBytes bytes');
    }
    yield chunk;
  }
}
