@TestOn('vm')
library;

import 'dart:async';

import 'package:keta/keta.dart';
import 'package:keta/test.dart';
import 'package:test/test.dart';

/// A [Log] that records every emitted line's merged fields into a shared list,
/// so a test can assert exactly what `accessLog` wrote. `withFields` returns a
/// view that keeps recording into the same store (the shape a real per-request
/// logger has: `c.log` is `env.log.withFields({reqId, route})`).
class RecordingLog implements Log {
  RecordingLog() : this._(const {}, []);
  RecordingLog._(this._baked, this.lines);
  final Map<String, Object?> _baked;

  /// One map per emitted line: `msg` plus the baked and per-call fields.
  final List<Map<String, Object?>> lines;

  void _record(String msg, Map<String, Object?> fields) =>
      lines.add({'msg': msg, ..._baked, ...fields});

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _record(msg, fields);
  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _record(msg, fields);
  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _record(msg, fields);
  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) => _record(msg, fields);

  @override
  Future<void> flush() async {}

  @override
  Log withFields(Map<String, Object?> fields) =>
      RecordingLog._({..._baked, ...fields}, lines);
}

class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

/// The single `request` line accessLog wrote against [c] for [response].
Future<Map<String, Object?>> logLineFor(
  Context<Env> c,
  RecordingLog log,
  Response response,
) async {
  await accessLog<Env>()(c, (_) => response);
  final request = log.lines.where((l) => l['msg'] == 'request').toList();
  expect(request, hasLength(1), reason: 'accessLog emits exactly one line');
  return request.single;
}

void main() {
  group('accessLog honesty (item 3a)', () {
    test('an upgrade response is logged with upgrade:true (101 declared)', () async {
      final log = RecordingLog();
      final c = testContext(Env(log));
      final line = await logLineFor(c, log, Response.upgrade((_) {}));
      // 101 is the *declared* status; the wire may still answer 426. The marker
      // says "the handler asked to switch", not "the switch happened".
      expect(line['status'], 101);
      expect(line['upgrade'], isTrue);
      // A declared-status upgrade is not a streamed body.
      expect(line.containsKey('streaming'), isFalse);
    });

    test('a streamed body is logged with streaming:true (ms is TTFB)', () async {
      final log = RecordingLog();
      final c = testContext(Env(log));
      final streamed = Response(
        200,
        body: const Stream<List<int>>.empty(),
      );
      final line = await logLineFor(c, log, streamed);
      expect(line['status'], 200);
      expect(line['streaming'], isTrue);
      expect(line.containsKey('upgrade'), isFalse);
    });

    test('an SSE response is logged with streaming:true', () async {
      final log = RecordingLog();
      final c = testContext(Env(log));
      final line = await logLineFor(
        c,
        log,
        c.sse(const Stream<SseEvent>.empty()),
      );
      expect(line['status'], 200);
      expect(line['streaming'], isTrue);
    });

    test('an ordinary buffered response carries neither marker', () async {
      final log = RecordingLog();
      final c = testContext(Env(log));
      final line = await logLineFor(c, log, Response.text('hi'));
      expect(line['status'], 200);
      expect(line.containsKey('upgrade'), isFalse);
      expect(line.containsKey('streaming'), isFalse);
    });
  });
}
