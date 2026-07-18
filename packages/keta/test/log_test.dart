/// Owns StdoutLog's buffered backlog: its byte bound and eviction of the
/// oldest lines, the honest reporting of what was dropped, and the shared
/// drain/timer that a per-request `withFields` view rides on.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:keta/keta.dart';
import 'package:test/test.dart';

/// A minimal IOSink that records written lines, for asserting on StdoutLog.
class _CaptureSink implements IOSink {
  final StringBuffer buffer = StringBuffer();
  String get text => buffer.toString();
  @override
  void writeln([Object? obj = '']) => buffer.writeln(obj);
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

const _overflowMsg = 'log backlog overflowed, oldest lines dropped';

/// A sink that refuses, the way a broken pipe or a full disk does.
class _BrokenSink extends _CaptureSink {
  bool broken = true;
  @override
  Future<void> flush() async {
    if (broken) throw const SocketException('broken pipe');
  }
}

/// A [_CaptureSink] that also notices whether two flushes are ever in flight at
/// once, and takes long enough to flush that an overlap has room to happen.
class _ConcurrencyCountingSink extends _CaptureSink {
  int _inFlight = 0;
  int peakConcurrentFlushes = 0;

  @override
  Future<void> flush() async {
    _inFlight++;
    if (_inFlight > peakConcurrentFlushes) peakConcurrentFlushes = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _inFlight--;
  }
}

void main() {
  test(
    'disposing a per-request log view leaves the shared timer running',
    () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final base = StdoutLog(
        sink: sink,
        flushInterval: const Duration(milliseconds: 20),
      );
      addTearDown(base.dispose);

      final view = base.withFields({'reqId': 'x'});
      (view as StdoutLog).dispose(); // must be a no-op — the timer is shared

      base.info('after-dispose');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(sink.text, contains('after-dispose')); // base still auto-flushed
    },
  );

  group('the backlog is bounded', () {
    // A sink that stops accepting must not be able to grow the backlog without
    // limit. Nothing here asserts on timing: the bound is a property of the
    // buffer, and it is asserted as one.

    test('an unstalled sink drops nothing', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final log = StdoutLog(sink: sink, flushInterval: Duration.zero);
      for (var i = 0; i < 500; i++) {
        log.info('line-$i');
      }
      await log.flush();
      expect(sink.text, isNot(contains('overflowed')));
      expect('\n'.allMatches(sink.text.trim()).length + 1, 500);
    });

    test('past the bound the oldest go, and the newest survive', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      // Room for a handful of lines, so the overflow is exact rather than
      // approximate.
      final log = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      for (var i = 0; i < 200; i++) {
        log.info('line-$i');
      }
      await log.flush();
      // The most recent line is the one worth keeping when a sink has stalled.
      expect(sink.text, contains('line-199'));
      expect(sink.text, isNot(contains('"msg":"line-0"')));
    });

    test('what was dropped is reported, not silently swallowed', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final log = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      for (var i = 0; i < 200; i++) {
        log.info('line-$i');
      }
      await log.flush();

      final lines = const LineSplitter()
          .convert(sink.text)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      final report = lines.firstWhere((l) => l['msg'] == _overflowMsg);
      expect(report['level'], 'warn');
      // Conservation, not just "some number": every line either arrived or was
      // counted. `greaterThan(0)` would hold just as well if the counter
      // double-incremented or slipped outside the eviction loop.
      final survived = lines.where((l) => l['msg'] != _overflowMsg).length;
      expect(survived + (report['dropped']! as int), 200);
    });

    test(
      'a line larger than the whole budget does not evict the rest',
      () async {
        // The oversized line is an error's stack trace far more often than not,
        // and the lines it would evict are the ones explaining how that error
        // was reached. Dropping the giant loses one line; admitting it loses all
        // the context and overshoots the bound anyway.
        final sink = _CaptureSink();
        addTearDown(sink.close);
        final log = StdoutLog(
          sink: sink,
          flushInterval: Duration.zero,
          maxBufferedBytes: 4000,
        );
        for (var i = 0; i < 20; i++) {
          log.info('keep-$i');
        }
        log.error('boom', StateError('x'), StackTrace.fromString('T' * 8000));
        await log.flush();

        for (var i = 0; i < 20; i++) {
          expect(sink.text, contains('keep-$i'));
        }
        final report = const LineSplitter()
            .convert(sink.text)
            .map((l) => jsonDecode(l) as Map<String, Object?>)
            .firstWhere((l) => l['msg'] == _overflowMsg);
        expect(report['dropped'], 1); // the giant, and only the giant
      },
    );

    test('the count resets once reported, and does not double-count', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final log = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      for (var i = 0; i < 200; i++) {
        log.info('line-$i');
      }
      await log.flush();
      sink.buffer.clear();

      // A quiet period after the overflow must not re-report the old loss.
      log.info('calm');
      await log.flush();
      expect(sink.text, contains('calm'));
      expect(sink.text, isNot(contains('overflowed')));
    });

    test('a view flushing mid-drain neither overlaps nor reorders', () async {
      // The drain yields between slices, and c.log is a view with its own
      // handle on flush(). If the serialization lived on the instance rather
      // than on the shared backlog, a view's flush would slot into one of those
      // yields: measured, the first view line landed at index 32 -- exactly one
      // slice in -- while base lines carried on after it. Interleaved lines are
      // worse than late ones, because the timestamps stop telling the truth
      // about order.
      final sink = _ConcurrencyCountingSink();
      addTearDown(sink.close);
      final base = StdoutLog(sink: sink, flushInterval: Duration.zero);
      final view = base.withFields({'reqId': 'r1'});

      for (var i = 0; i < 1000; i++) {
        base.info('BASE-$i');
      }
      final baseFlush = base.flush(); // snapshots, writes a slice, yields
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 1000; i++) {
        view.info('VIEW-$i');
      }
      await Future.wait([baseFlush, view.flush()]);

      final msgs = const LineSplitter()
          .convert(sink.text)
          .map((l) => (jsonDecode(l) as Map<String, Object?>)['msg']! as String)
          .toList();
      final firstView = msgs.indexWhere((m) => m.startsWith('VIEW'));
      final lastBase = msgs.lastIndexWhere((m) => m.startsWith('BASE'));
      expect(
        lastBase,
        lessThan(firstView),
        reason: 'every BASE line was enqueued before any VIEW line existed',
      );
      expect(
        sink.peakConcurrentFlushes,
        1,
        reason: 'overlapping IOSink.flush() is what the chain must prevent',
      );
    });

    test('a refusing sink does not make flush() the caller problem', () async {
      // Every shutdown path is `await log.flush(); dispose();`. If flush()
      // rejected, dispose() would be skipped, the periodic timer would survive,
      // and the isolate would never exit — the process hanging because logging
      // failed. Awaiting must simply complete.
      final sink = _BrokenSink();
      addTearDown(sink.close);
      final log = StdoutLog(sink: sink, flushInterval: Duration.zero);
      log.info('x');
      await expectLater(log.flush(), completes);
    });

    test(
      'a failed drain carries its gap forward instead of erasing it',
      () async {
        final sink = _BrokenSink();
        addTearDown(sink.close);
        final log = StdoutLog(
          sink: sink,
          flushInterval: Duration.zero,
          maxBufferedBytes: 400,
        );
        for (var i = 0; i < 200; i++) {
          log.info('line-$i');
        }
        await log.flush(); // rejects internally: nothing was delivered
        sink.buffer.clear();

        // The sink comes back. The gap from the failed drain must still be
        // reported -- zeroing the counter on a drain that never landed is how a
        // gap goes silent, which is the one thing the bound exists to prevent.
        sink.broken = false;
        log.info('after-recovery');
        await log.flush();
        final report = const LineSplitter()
            .convert(sink.text)
            .map((l) => jsonDecode(l) as Map<String, Object?>)
            .firstWhere((l) => l['msg'] == _overflowMsg);
        // The evicted lines AND the batch the broken sink swallowed.
        expect(report['dropped'], 200);
      },
    );

    test('a view shares the backlog, so its lines are bounded too', () async {
      final sink = _CaptureSink();
      addTearDown(sink.close);
      final base = StdoutLog(
        sink: sink,
        flushInterval: Duration.zero,
        maxBufferedBytes: 400,
      );
      final view = base.withFields({'reqId': 'r1'});
      for (var i = 0; i < 200; i++) {
        view.info('line-$i');
      }
      // Flushing through the base must see what the view enqueued, and must
      // account for what the view's overflow dropped.
      await base.flush();
      expect(sink.text, contains('overflowed'));
      expect(sink.text, contains('r1'));
    });
  });
}
