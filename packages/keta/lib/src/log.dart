library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Structured logger. Every method enqueues synchronously; flushing is
/// deferred to a per-isolate timer and to shutdown.
abstract interface class Log {
  void debug(String msg, [Map<String, Object?> fields]);
  void info(String msg, [Map<String, Object?> fields]);
  void warn(String msg, [Map<String, Object?> fields]);
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields,
  ]);

  /// Flush buffered lines. Called on a background timer and at shutdown.
  Future<void> flush();

  /// Returns a view of this log that adds [fields] to every line it emits.
  Log withFields(Map<String, Object?> fields);
}

/// The backlog behind a [StdoutLog] and every view [withFields] makes of it.
///
/// Bounded, because a sink that stops accepting must not be able to grow it
/// without limit. Bounded by size rather than by line count: the flood that
/// fills it is usually stack traces, and counting those as one line each budgets
/// nothing.
class _Backlog {
  _Backlog(this.maxBytes);

  /// Measured as string length. That is what the retained memory tracks, and
  /// for the ASCII-dominant JSON emitted here it tracks the bytes written too.
  final int maxBytes;
  final ListQueue<String> _lines = ListQueue<String>();
  int _bytes = 0;

  /// Lines discarded since the last drain reported them. Never silently reset.
  int dropped = 0;

  /// Serializes drains across the owner AND every view of it. It lives here,
  /// with the buffer, because that is the scope it has to cover: views share
  /// the sink, so two of them flushing at once overlap `IOSink.flush()` calls
  /// on the same sink. A per-instance chain only serializes an instance
  /// against itself, which is not the hazard.
  Future<void> flushing = Future<void>.value();

  bool get isEmpty => _lines.isEmpty && dropped == 0;

  void add(String line) {
    // A line that cannot fit even into an empty backlog is dropped whole rather
    // than admitted. Evicting for it would empty the queue and still overshoot
    // the bound, and what it evicts is the worst possible thing to lose: an
    // error's stack trace is exactly the line most likely to be oversized, and
    // the lines it would evict are the ones explaining how that error was
    // reached.
    if (line.length > maxBytes) {
      dropped++;
      return;
    }
    // The oldest go first: once a sink has stalled, the lines worth keeping are
    // the ones describing the state it is in now, not the ones from before it
    // broke.
    while (_bytes + line.length > maxBytes && _lines.isNotEmpty) {
      _bytes -= _lines.removeFirst().length;
      dropped++;
    }
    _lines.addLast(line);
    _bytes += line.length;
  }

  List<String> takeAll() {
    final all = _lines.toList(growable: false);
    _lines.clear();
    _bytes = 0;
    return all;
  }
}

/// Writes one JSON line per event: `{"ts","level","msg", ...fields}`.
///
/// Lines are buffered and flushed on a timer to keep log calls off the hot
/// path. [flush] drains synchronously-accumulated lines to the sink.
class StdoutLog implements Log {
  /// [sink] defaults to `stdout.nonBlocking`, NOT to `stdout`. dart:io's plain
  /// `stdout` is documented as blocking, so if whatever reads it stops — a
  /// paused log collector, a full disk, a pipe nobody drains — the write blocks
  /// and the isolate stops serving for exactly as long as the reader is stuck.
  /// Measured: at 2k lines/s, a reader asleep 6s froze the whole server for 6s.
  /// No one would choose that, so it is not the default; pass `sink: stdout`
  /// to opt into blocking delivery.
  ///
  /// [maxBufferedBytes] bounds what a stalled sink can accumulate. Past it the
  /// oldest lines are dropped and the count is reported on the next successful
  /// drain — losing logs beats losing the server, but losing them silently is
  /// not on the menu. The line being added is never the one dropped, so the
  /// backlog can exceed the bound by one line (a lone stack trace bigger than
  /// the whole budget still gets through, rather than vanishing).
  StdoutLog({
    IOSink? sink,
    Duration flushInterval = const Duration(seconds: 1),
    int maxBufferedBytes = defaultMaxBufferedBytes,
  }) : _sink = sink ?? stdout.nonBlocking,
       _baked = const {},
       _buffer = _Backlog(maxBufferedBytes),
       _ownsTimer = true {
    if (flushInterval > Duration.zero) {
      _timer = Timer.periodic(flushInterval, (_) => flush());
    }
  }

  StdoutLog._view(this._sink, this._buffer, this._baked, this._timer)
    : _ownsTimer = false;

  /// Headroom for a stalled sink, per isolate.
  static const defaultMaxBufferedBytes = 8 * 1024 * 1024;

  final IOSink _sink;
  final Map<String, Object?> _baked;
  final _Backlog _buffer;
  Timer? _timer;
  // Only the StdoutLog that created the timer may cancel it; a per-request view
  // (from withFields) shares the timer and must never dispose it.
  final bool _ownsTimer;

  /// Lines written per event-loop turn. Chosen by measurement, not derivation:
  /// against 256 and 2048 it halved the worst stall under a 50k lines/s
  /// synthetic load (5.0ms vs 10.7ms and 10.5ms) and cost no throughput over
  /// HTTP. The stall is not proportional to this — 256 and 2048 measured the
  /// same — so the remainder comes from somewhere else and a smaller batch does
  /// not keep paying off.
  static const _maxBatch = 32;

  @override
  Log withFields(Map<String, Object?> fields) {
    if (fields.isEmpty) return this;
    // The view shares the sink, buffer, and timer; only the baked-in fields
    // differ, so a per-request logger costs a single small map.
    return StdoutLog._view(_sink, _buffer, {..._baked, ...fields}, _timer);
  }

  void _emit(
    String level,
    String msg,
    Map<String, Object?> fields, {
    Object? error,
    StackTrace? st,
  }) {
    final line = <String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'msg': msg,
      ..._baked,
      ...fields,
    };
    if (error != null) line['error'] = error.toString();
    if (st != null) line['stack'] = st.toString();
    _buffer.add(jsonEncode(line));
  }

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _emit('debug', msg, fields);

  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _emit('info', msg, fields);

  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _emit('warn', msg, fields);

  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) => _emit('error', msg, fields, error: error, st: st);

  @override
  Future<void> flush() {
    // Chain onto any in-flight flush: overlapping IOSink.flush() calls (the
    // background timer racing a shutdown flush, an app calling c.log.flush(),
    // or a slow sink) would throw "StreamSink is bound to a stream".
    // Serializing them keeps the error off the root zone. The chain lives on
    // the shared backlog, not on this instance: c.log is a view, and a
    // per-instance chain would let a view's flush overlap the owner's.
    //
    // The guarded future is what callers get, so this never rejects. A broken
    // sink must not become the caller's problem: every shutdown path is
    // `await log.flush(); dispose();`, so a rejecting flush would skip
    // dispose(), leave the periodic timer alive, and hang the process on a
    // logging failure. A logger that cannot write is not a reason to refuse to
    // exit. What was lost is accounted for in [_Backlog.dropped] instead.
    _buffer.flushing = _buffer.flushing
        .then((_) => _drain())
        .catchError((_) {});
    return _buffer.flushing;
  }

  Future<void> _drain() async {
    if (_buffer.isEmpty) return;
    final dropped = _buffer.dropped;
    _buffer.dropped = 0;
    // Snapshot then clear before awaiting, so lines enqueued during the flush
    // are retained for the next drain rather than dropped.
    final pending = _buffer.takeAll();
    try {
      await _write(pending, dropped);
    } catch (_) {
      // The sink refused, so none of this reached anyone. Neither the count nor
      // this batch may evaporate: fold both back so the next drain that does
      // land reports the whole gap. Without this, a broken pipe zeroes the
      // counter and the gap the class promises to report disappears silently —
      // which is the one outcome the bound exists to rule out.
      _buffer.dropped += dropped + pending.length;
      rethrow;
    }
  }

  /// Writes [dropped]'s report (if any) then [pending], in bounded slices.
  Future<void> _write(List<String> pending, int dropped) async {
    if (dropped > 0) {
      // In band, ahead of the lines that survived: a gap the operator cannot
      // see is worse than the gap itself.
      _sink.writeln(
        jsonEncode({
          'ts': DateTime.now().toUtc().toIso8601String(),
          'level': 'warn',
          'msg': 'log backlog overflowed, oldest lines dropped',
          'dropped': dropped,
        }),
      );
    }
    // Written in bounded slices, yielding to the event loop between them.
    //
    // One synchronous loop over the whole snapshot holds the loop for a time
    // proportional to how many lines accumulated -- that is, proportional to
    // throughput, so the harder the server worked the longer it stopped
    // serving. Measured at a 1s interval: 5k lines/s froze it 5.9ms, 20k froze
    // it 12.7ms, 50k froze it 33.7ms; over HTTP the worst response went to
    // 15ms. Slicing cuts that to ~2.5ms over HTTP at the same throughput, with
    // every line still written.
    //
    // Duration.zero, not an await on the sink: an await only reaches timers and
    // IO if the future is not already complete, and awaiting the sink every
    // slice paces the drain to the sink instead of to the producer -- which
    // measured 18% less throughput and left 87% of lines unwritten under load.
    // The sink is therefore flushed once, at the end.
    for (var i = 0; i < pending.length; i += _maxBatch) {
      final end = i + _maxBatch < pending.length
          ? i + _maxBatch
          : pending.length;
      for (var j = i; j < end; j++) {
        _sink.writeln(pending[j]);
      }
      if (end < pending.length) await Future<void>.delayed(Duration.zero);
    }
    await _sink.flush();
  }

  /// Stops the background flush timer. Call once at shutdown, after a final
  /// [flush]. A per-request view (from [withFields]) shares the owner's timer,
  /// so calling this on a view is a safe no-op rather than killing isolate-wide
  /// flushing.
  void dispose() {
    if (!_ownsTimer) return;
    _timer?.cancel();
    _timer = null;
  }
}
