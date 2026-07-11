library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Structured logger. Every method enqueues synchronously; flushing is
/// deferred to a per-isolate timer and to shutdown.
abstract interface class Log {
  void debug(String msg, [Map<String, Object?> fields]);
  void info(String msg, [Map<String, Object?> fields]);
  void warn(String msg, [Map<String, Object?> fields]);
  void error(String msg,
      [Object? error, StackTrace? st, Map<String, Object?> fields]);

  /// Flush buffered lines. Called on a background timer and at shutdown.
  Future<void> flush();

  /// Returns a view of this log that adds [fields] to every line it emits.
  Log withFields(Map<String, Object?> fields);
}

/// Writes one JSON line per event: `{"ts","level","msg", ...fields}`.
///
/// Lines are buffered and flushed on a timer to keep log calls off the hot
/// path. [flush] drains synchronously-accumulated lines to the sink.
class StdoutLog implements Log {
  final IOSink _sink;
  final Map<String, Object?> _baked;
  final List<String> _buffer;
  Timer? _timer;

  StdoutLog({IOSink? sink, Duration flushInterval = const Duration(seconds: 1)})
      : _sink = sink ?? stdout,
        _baked = const {},
        _buffer = <String>[] {
    if (flushInterval > Duration.zero) {
      _timer = Timer.periodic(flushInterval, (_) => flush());
    }
  }

  StdoutLog._view(this._sink, this._buffer, this._baked, this._timer);

  @override
  Log withFields(Map<String, Object?> fields) {
    if (fields.isEmpty) return this;
    // The view shares the sink, buffer, and timer; only the baked-in fields
    // differ, so a per-request logger costs a single small map.
    return StdoutLog._view(_sink, _buffer, {..._baked, ...fields}, _timer);
  }

  void _emit(String level, String msg, Map<String, Object?> fields,
      {Object? error, StackTrace? st}) {
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
  void error(String msg,
      [Object? error,
      StackTrace? st,
      Map<String, Object?> fields = const {}]) =>
      _emit('error', msg, fields, error: error, st: st);

  @override
  Future<void> flush() async {
    if (_buffer.isEmpty) return;
    // Snapshot then clear before awaiting, so lines enqueued during the flush
    // are retained for the next drain rather than dropped.
    final pending = _buffer.toList(growable: false);
    _buffer.clear();
    for (final line in pending) {
      _sink.writeln(line);
    }
    await _sink.flush();
  }

  /// Stops the background flush timer. Call once at shutdown, after a final
  /// [flush]; per-request views must not be disposed (they share this timer).
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
