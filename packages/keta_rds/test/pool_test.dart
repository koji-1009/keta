/// Pins Pool's invariants: checkout/reuse up to the ceiling, exhaustion and
/// FIFO waiter release, failed-open recovery, broken-resource disposal,
/// close draining, release guards, validate, and the idle reaper.
library;

import 'dart:async';

import 'package:keta/keta.dart' show Unavailable;
import 'package:keta_rds/src/pool.dart';
import 'package:test/test.dart';

/// A stand-in resource: knows its id, whether it was disposed, and whether it
/// still validates (stands in for a driver connection's `isOpen`).
class FakeConn {
  FakeConn(this.id);
  final int id;
  bool closed = false;
  bool open = true;
}

/// A counting factory so a test can assert how many resources were opened and
/// disposed without any real Postgres.
class Factory {
  int opened = 0;
  int closed = 0;
  bool failNextOpen = false;

  Future<FakeConn> open() async {
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('open failed');
    }
    return FakeConn(opened++);
  }

  Future<void> close(FakeConn c) async {
    c.closed = true;
    closed++;
  }
}

void main() {
  group('checkout and reuse', () {
    test('an idle resource is reused rather than reopened', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);

      final a = await pool.acquire();
      pool.release(a);
      final b = await pool.acquire();

      expect(identical(a, b), isTrue);
      expect(f.opened, 1); // reused, not reopened
      expect(pool.checkedOut, 1);
    });

    test('opens up to the ceiling, then reuses', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);

      final a = await pool.acquire();
      final b = await pool.acquire();
      expect(f.opened, 2);
      expect(pool.checkedOut, 2);

      pool.release(a);
      pool.release(b);
      await pool.acquire();
      await pool.acquire();
      expect(f.opened, 2); // both reused; the ceiling was never exceeded
    });
  });

  group('exhaustion', () {
    test(
      'a checkout past the ceiling waits, then a 503 when nothing frees up',
      () async {
        final f = Factory();
        final pool = Pool<FakeConn>(
          f.open,
          f.close,
          maxConnections: 1,
          acquireTimeout: const Duration(milliseconds: 50),
        );

        await pool.acquire(); // holds the only slot, never released

        await expectLater(
          pool.acquire(),
          throwsA(isA<Unavailable>().having((e) => e.status, 'status', 503)),
        );
      },
    );

    test('a waiter proceeds as soon as a slot is released (FIFO)', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(
        f.open,
        f.close,
        maxConnections: 1,
        acquireTimeout: const Duration(seconds: 5),
      );

      final a = await pool.acquire();
      final waiting = pool.acquire(); // parks behind a

      await Future<void>.delayed(const Duration(milliseconds: 10));
      pool.release(a);

      final b = await waiting;
      expect(identical(a, b), isTrue); // handed the freed connection
      expect(f.opened, 1);
    });
  });

  group('failed open', () {
    test('propagates and frees the slot for the next caller', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 1);

      f.failNextOpen = true;
      await expectLater(pool.acquire(), throwsStateError);
      expect(pool.checkedOut, 0); // the failed checkout was undone

      // The slot is free again, so a real connection can still be opened.
      final c = await pool.acquire();
      expect(c, isA<FakeConn>());
    });

    test(
      'close() completes when the in-flight open fails after close begins',
      () async {
        // Regression: acquire()'s catch clause used to undo the checkout and
        // hand the slot back without nudging the drain, so a close() that
        // started while this was the last outstanding checkout hung forever
        // waiting on a resource that was never actually handed out.
        final openGate = Completer<FakeConn>();
        final closed = <FakeConn>[];
        final pool = Pool<FakeConn>(
          () => openGate.future,
          (c) async => closed.add(c),
          maxConnections: 1,
        );

        final acquiring = pool.acquire();
        // No idle resource and the ceiling has room, so acquire() is now
        // awaiting _open() — the sole outstanding checkout.
        await Future<void>.delayed(Duration.zero);

        final closing = pool.close();
        var isClosed = false;
        unawaited(closing.then((_) => isClosed = true));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(isClosed, isFalse); // still draining the in-flight open

        openGate.completeError(StateError('open failed'));
        await expectLater(acquiring, throwsStateError);
        await closing.timeout(
          const Duration(seconds: 1),
          onTimeout: () => fail('close() hung on a failed in-flight open'),
        );
        expect(isClosed, isTrue);
      },
    );
  });

  group('release of a broken resource', () {
    test('is disposed, not returned to the pool', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);

      final a = await pool.acquire();
      pool.release(a, broken: true);
      expect(a.closed, isTrue);
      expect(pool.idle, 0);

      final b = await pool.acquire();
      expect(identical(a, b), isFalse); // a fresh one, not the broken one
      expect(f.opened, 2);
    });
  });

  group('close', () {
    test('disposes idle resources and rejects further checkouts', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);

      final a = await pool.acquire();
      pool.release(a); // now idle
      await pool.close();

      expect(a.closed, isTrue);
      expect(pool.isClosed, isTrue);
      await expectLater(pool.acquire(), throwsStateError);
    });

    test('waits for an in-flight checkout, then disposes it', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);

      final a = await pool.acquire(); // still checked out
      final closing = pool.close();

      var closed = false;
      unawaited(closing.then((_) => closed = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closed, isFalse); // blocked on the in-flight checkout

      pool.release(a);
      await closing;
      expect(closed, isTrue);
      expect(a.closed, isTrue); // released after close → disposed
    });

    test('is idempotent', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 1);
      await pool.close();
      await pool.close(); // must not throw
    });

    test('a waiter parked at close fails with StateError', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(
        f.open,
        f.close,
        maxConnections: 1,
        acquireTimeout: const Duration(seconds: 5),
      );
      final a = await pool.acquire(); // holds the slot
      final waiting = pool.acquire(); // parks

      final closing = pool.close(); // drains once the held slot returns
      await expectLater(waiting, throwsStateError);

      pool.release(a); // let close() finish rather than hang on the drain
      await closing;
    });
  });

  group('release guard', () {
    test('a double release throws instead of corrupting the counts', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);

      final a = await pool.acquire();
      pool.release(a);
      expect(() => pool.release(a), throwsStateError);
      // The bogus second release must not have handed back a phantom permit:
      // the pool still tops out at maxConnections concurrent checkouts.
      expect(pool.checkedOut, 0);
      expect(pool.idle, 1); // the one legitimate release, not two
    });

    test('releasing a foreign resource throws', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(f.open, f.close, maxConnections: 2);
      await pool.acquire();
      expect(() => pool.release(FakeConn(99)), throwsStateError);
      expect(pool.checkedOut, 1); // untouched
    });
  });

  group('validate', () {
    test(
      'acquire skips a resource that no longer validates, opening fresh',
      () async {
        final f = Factory();
        final pool = Pool<FakeConn>(
          f.open,
          f.close,
          maxConnections: 2,
          validate: (c) => c.open,
        );

        final a = await pool.acquire();
        pool.release(a); // now idle
        a.open = false; // the server dropped it while it sat idle

        final b = await pool.acquire();
        expect(identical(a, b), isFalse); // not the dead one
        expect(a.closed, isTrue); // the dead one was disposed
        expect(f.opened, 2); // a fresh connection was opened
        expect(pool.idle, 0);
      },
    );

    test('a still-valid idle resource is reused', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(
        f.open,
        f.close,
        maxConnections: 2,
        validate: (c) => c.open,
      );
      final a = await pool.acquire();
      pool.release(a);
      final b = await pool.acquire();
      expect(identical(a, b), isTrue);
      expect(f.opened, 1);
    });

    test(
      'a validate that throws disposes the resource and restores pool state',
      () async {
        // Regression: the idle-drain loop called validate() with no guard.
        // A throw (as opposed to a returned false) left the popped resource
        // neither idle, in _out, nor disposed, and the permit/checkout it took
        // in acquire() before the loop was never given back — repeated hits
        // would wedge the pool at a permanently lower effective ceiling.
        final f = Factory();
        var throwNext = false;
        final pool = Pool<FakeConn>(
          f.open,
          f.close,
          maxConnections: 2,
          validate: (c) {
            if (throwNext) {
              throwNext = false;
              throw StateError('validate blew up');
            }
            return c.open;
          },
        );

        final a = await pool.acquire();
        pool.release(a); // now idle
        throwNext = true;

        await expectLater(pool.acquire(), throwsStateError);
        // Fully restored: no leaked checkout, no phantom idle entry, and the
        // resource that took the throw was disposed rather than orphaned.
        expect(pool.checkedOut, 0);
        expect(pool.idle, 0);
        expect(a.closed, isTrue);

        // Not wedged: a normal acquire still succeeds afterward.
        final b = await pool.acquire();
        expect(b, isA<FakeConn>());
        expect(pool.checkedOut, 1);
      },
    );
  });

  group('idle reaper', () {
    test(
      'disposes an idle-expired connection; the pool reopens on demand',
      () async {
        final f = Factory();
        final pool = Pool<FakeConn>(
          f.open,
          f.close,
          maxConnections: 2,
          maxIdleTime: const Duration(milliseconds: 100),
        );

        final a = await pool.acquire();
        pool.release(a); // idle, reaper now armed
        expect(pool.idle, 1);
        expect(pool.reaperActive, isTrue);

        // The reaper ticks at maxIdleTime/2 (50ms), so the worst case for
        // disposing a resource that just missed a tick is ~1.5x maxIdleTime
        // (150ms), guaranteed caught by the tick at 150ms. 170ms clears that
        // with margin while staying comfortably under the pre-fix worst case
        // of 2x maxIdleTime (200ms), so this wait is itself evidence the
        // tighter bound is in effect, not just that reaping eventually happens.
        await Future<void>.delayed(const Duration(milliseconds: 170));
        expect(a.closed, isTrue); // reaped
        expect(pool.idle, 0);
        expect(pool.reaperActive, isFalse); // self-cancelled once idle emptied

        final b = await pool.acquire(); // reopens on demand
        expect(identical(a, b), isFalse);
        expect(f.opened, 2);
      },
    );

    test('a non-positive maxIdleTime never arms the reaper', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(
        f.open,
        f.close,
        maxConnections: 2,
        maxIdleTime: Duration.zero,
      );
      final a = await pool.acquire();
      pool.release(a);
      expect(pool.idle, 1);
      expect(pool.reaperActive, isFalse);
    });

    test('close cancels the reaper', () async {
      final f = Factory();
      final pool = Pool<FakeConn>(
        f.open,
        f.close,
        maxConnections: 2,
        maxIdleTime: const Duration(seconds: 5),
      );
      final a = await pool.acquire();
      pool.release(a);
      expect(pool.reaperActive, isTrue);

      await pool.close();
      expect(pool.reaperActive, isFalse); // no timer left pinning the isolate
      expect(a.closed, isTrue);
    });
  });

  test('maxConnections below 1 is rejected at construction', () {
    final f = Factory();
    expect(
      () => Pool<FakeConn>(f.open, f.close, maxConnections: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}
