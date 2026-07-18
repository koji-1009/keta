library;

import 'dart:async';
import 'dart:collection';

import 'package:keta/keta.dart' show Unavailable;

/// A bounded pool of reusable resources of type [C] — a database connection in
/// keta_rds, but kept generic on purpose so the checkout / return / exhaustion
/// logic can be exercised by a unit test with a trivial fake factory, with no
/// Postgres server in sight.
///
/// At most [maxConnections] resources are ever live at once. Opening is lazy: a
/// resource is created only when a checkout finds none idle and the ceiling is
/// not yet reached, and an idle resource is reused in preference to opening a
/// new one. A caller that cannot be handed a resource within [acquireTimeout]
/// gets a keta [Unavailable] (503) rather than waiting forever — a saturated
/// pool is transient overload, the same "resource unobtainable in time"
/// condition keta_sqlite's lock queue maps to 503.
///
/// The pool owns nothing about the wire protocol: [_open] creates a resource
/// and [_closeResource] disposes one, and everything in between is the caller's.
class Pool<C> {
  Pool(
    this._open,
    this._closeResource, {
    this.maxConnections = 10,
    this.acquireTimeout = const Duration(seconds: 30),
    this.maxIdleTime = const Duration(minutes: 5),
    this.validate,
  }) {
    if (maxConnections < 1) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'must be at least 1',
      );
    }
  }

  final Future<C> Function() _open;
  final Future<void> Function(C) _closeResource;

  /// Predicate applied to an idle resource just before it is handed out: a
  /// resource that fails it is disposed and skipped rather than returned to a
  /// caller. Wired from the driver's own liveness check (a connection's
  /// `isOpen`), it turns a connection the server or a proxy silently dropped
  /// while it sat idle into a fresh open, instead of one failed query. Null
  /// means "always valid" — the pool cannot second-guess an opaque resource.
  final bool Function(C)? validate;

  /// The ceiling on live resources (idle plus checked out).
  final int maxConnections;

  /// How long [acquire] waits for a free slot before giving up with a 503.
  final Duration acquireTimeout;

  /// How long a returned resource may sit idle before the reaper disposes it.
  ///
  /// A connection idle past a middlebox's own idle timeout — RDS Proxy, a NAT
  /// gateway, an LB — is already dead on the wire; the middlebox tore it down
  /// and the next `acquire` would otherwise pay one failed query to discover
  /// that. Reaping ahead of that deadline keeps the idle pool warm-only, so a
  /// caller is never handed a corpse. A non-positive duration disables the
  /// reaper entirely (no periodic timer is ever armed). Default 5 minutes sits
  /// under the common proxy/NAT idle timeouts (RDS Proxy's is minutes, many
  /// NATs 350s) — but note the worst-case bound below is ~1.5x this value, not
  /// this value itself.
  final Duration maxIdleTime;

  final ListQueue<_Idle<C>> _idle = ListQueue<_Idle<C>>();
  final ListQueue<Completer<void>> _waiters = ListQueue<Completer<void>>();

  // The resources genuinely checked out right now, by identity. release() is a
  // membership test against this set: a double release, or a resource this pool
  // never handed out, would otherwise silently decrement _checkedOut and hand
  // back a permit it does not own — inflating the permit count until the pool
  // runs more than maxConnections concurrent checkouts. Identity (not value)
  // because two distinct connections must never be conflated.
  final Set<C> _out = Set<C>.identity();

  /// Free slots. A slot is held from the moment a checkout is granted until the
  /// resource is released, so this bounds concurrent checkouts to
  /// [maxConnections] regardless of how many resources have actually been
  /// opened.
  late int _permits = maxConnections;
  int _checkedOut = 0;
  bool _closed = false;
  Completer<void>? _drained;
  // The reaper. Armed only while idle inventory exists (see [_syncReaper]) so a
  // pool with an empty idle set — or a closed one — never pins its isolate on a
  // periodic timer, mirroring keta core's StdoutLog dispose discipline.
  Timer? _reaper;

  /// Resources currently checked out (for tests and diagnostics).
  int get checkedOut => _checkedOut;

  /// Resources sitting idle, ready to be reused (for tests and diagnostics).
  int get idle => _idle.length;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Whether the idle reaper timer is currently armed (for tests and
  /// diagnostics). True only while idle inventory exists on an open pool; [close]
  /// and an emptied idle set both drop it back to false (see [_syncReaper]).
  bool get reaperActive => _reaper != null;

  /// Checks out a resource, opening a fresh one only if none is idle and the
  /// ceiling has room. Waits up to [acquireTimeout] for a slot when saturated,
  /// then throws [Unavailable]. Throws [StateError] once the pool is closed.
  Future<C> acquire() async {
    if (_closed) throw StateError('the connection pool is closed');
    await _takePermit();
    // A permit in hand: at most maxConnections callers stand here at once.
    if (_closed) {
      _givePermit();
      throw StateError('the connection pool is closed');
    }
    _checkedOut++;
    // Reuse the most recently returned idle resource (LIFO keeps the hot ones
    // warm and lets the oldest age out to the reaper), skipping any that no
    // longer validates — the server may have dropped it while it sat idle.
    while (_idle.isNotEmpty) {
      final resource = _idle.removeLast().resource;
      _syncReaper();
      bool valid;
      try {
        valid = validate == null || validate!(resource);
      } catch (_) {
        // validate() itself threw — not "returned false". The resource is
        // already popped from _idle and this checkout already holds a permit
        // and counts against _checkedOut, so an unguarded rethrow here would
        // leak both: the resource ends up neither idle, in _out, nor disposed,
        // and repeated occurrences wedge the pool at a permanently lower
        // effective ceiling (eventually permanent 503s). Mirror _open's catch
        // below: dispose the resource, undo the checkout and permit, nudge a
        // drain in progress, then rethrow.
        unawaited(_safeClose(resource));
        _checkedOut--;
        _givePermit();
        _finishDrainIfIdle();
        rethrow;
      }
      if (valid) {
        _out.add(resource);
        return resource;
      }
      // Dead in the pool: dispose it and try the next idle resource, or open a
      // fresh one below. It held no permit, so nothing to hand back.
      unawaited(_safeClose(resource));
    }
    try {
      final resource = await _open();
      _out.add(resource);
      return resource;
    } catch (_) {
      // Opening failed, so no resource was actually taken: undo the checkout
      // and hand the slot back (a waiter, if any, gets to try). The error
      // propagates to the caller, where RdsDb translates an unreachable server
      // into Unavailable. This checkout may also be the one close() is
      // draining on — nudge it the same way release() does, or a close() that
      // started while this open was in flight hangs forever on a checkout
      // that never comes back.
      _checkedOut--;
      _givePermit();
      _finishDrainIfIdle();
      rethrow;
    }
  }

  /// Returns a resource to the pool. A [broken] resource (or any resource
  /// returned after [close]) is disposed instead of being put back, so a
  /// connection the driver has already torn down is never handed out again.
  ///
  /// Throws [StateError] if [resource] is not one this pool currently has
  /// checked out — a double release or a foreign resource. Left unguarded, such
  /// a call would decrement the checkout count and hand back a permit the pool
  /// never lent, quietly letting concurrent checkouts climb past
  /// [maxConnections]; a loud failure at the call site is the only honest answer.
  void release(C resource, {bool broken = false}) {
    if (!_out.remove(resource)) {
      throw StateError(
        'released a resource this pool did not have checked out '
        '(double release, or a resource from a different pool)',
      );
    }
    _checkedOut--;
    if (broken || _closed) {
      unawaited(_safeClose(resource));
    } else {
      _idle.add(_Idle(resource, DateTime.now()));
      _syncReaper();
    }
    _givePermit();
    _finishDrainIfIdle();
  }

  /// Closes the pool: rejects waiters and future [acquire]s, disposes every
  /// idle resource now, and completes once every checked-out resource has been
  /// returned (a checked-out call is never interrupted). Idempotent.
  Future<void> close() async {
    if (_closed) return _drained?.future ?? Future<void>.value();
    _closed = true;
    // Stop the reaper before anything can await: a periodic timer left armed
    // would keep the isolate alive past close(), and _syncReaper cancels it
    // because _closed is now set.
    _syncReaper();
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(
        StateError('the connection pool is closed'),
      );
    }
    final idle = _idle.toList(growable: false);
    _idle.clear();
    for (final entry in idle) {
      await _safeClose(entry.resource);
    }
    if (_checkedOut == 0) return;
    // Wait for the in-flight checkouts to drain; each release() disposes its
    // resource (because _closed is set) and nudges this completer.
    return (_drained = Completer<void>()).future;
  }

  Future<void> _takePermit() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      acquireTimeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw const Unavailable(
          'database busy: could not acquire a pooled connection in time',
        );
      },
    );
  }

  void _givePermit() {
    if (_waiters.isNotEmpty) {
      // Transfer the slot straight to the next waiter (no counter round-trip),
      // preserving FIFO fairness.
      _waiters.removeFirst().complete();
    } else {
      _permits++;
    }
  }

  void _finishDrainIfIdle() {
    final drained = _drained;
    if (_closed &&
        _checkedOut == 0 &&
        drained != null &&
        !drained.isCompleted) {
      drained.complete();
    }
  }

  Future<void> _safeClose(C resource) async {
    try {
      await _closeResource(resource);
    } catch (_) {
      // A failure while disposing a resource is not the caller's problem, and
      // there is nothing useful to do with it here.
    }
  }

  /// Keeps the reaper armed exactly when there is idle inventory worth watching.
  ///
  /// The invariant is "a periodic timer runs iff [maxIdleTime] is positive, the
  /// pool is open, and [_idle] is non-empty". Called after every change to
  /// [_idle] or [_closed], it starts the timer when the first resource goes
  /// idle and cancels it the moment the idle set empties (reaped, reused, or
  /// closed) — so an idle-free or closed pool holds no timer and never pins its
  /// isolate, the same posture as StdoutLog.dispose() cancelling its flush
  /// timer.
  ///
  /// Ticks at `maxIdleTime / 2`, not `maxIdleTime`: a resource can go idle right
  /// after a tick and then wait a full further period before the *next* tick
  /// even notices it is overdue, so ticking at the full [maxIdleTime] makes the
  /// worst-case time-to-disposal ~2x [maxIdleTime] — exactly the gap a
  /// middlebox with, say, a 350s idle timeout and a naively-ticked 5-minute
  /// reaper would fall into (2x5min = 600s, already past 350s). Halving the
  /// tick caps the worst case at ~1.5x [maxIdleTime] instead.
  void _syncReaper() {
    final wanted = !_closed && maxIdleTime > Duration.zero && _idle.isNotEmpty;
    if (wanted && _reaper == null) {
      _reaper = Timer.periodic(maxIdleTime ~/ 2, (_) => _reap());
    } else if (!wanted && _reaper != null) {
      _reaper!.cancel();
      _reaper = null;
    }
  }

  /// Disposes every idle resource that has sat longer than [maxIdleTime].
  ///
  /// Entries are appended at return time, so [_idle] is ordered oldest-first
  /// (reuse pops the newest off the back); the scan stops at the first entry
  /// still within its window. Disposed resources held no permit, so nothing is
  /// handed back — the ceiling is untouched and the next acquire opens fresh.
  void _reap() {
    final now = DateTime.now();
    while (_idle.isNotEmpty &&
        now.difference(_idle.first.returnedAt) >= maxIdleTime) {
      unawaited(_safeClose(_idle.removeFirst().resource));
    }
    _syncReaper();
  }
}

/// An idle resource paired with the instant it was returned, so the reaper can
/// tell a warm resource from one that has outlived [Pool.maxIdleTime].
class _Idle<C> {
  _Idle(this.resource, this.returnedAt);
  final C resource;
  final DateTime returnedAt;
}
