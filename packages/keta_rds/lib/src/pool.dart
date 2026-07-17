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

  /// The ceiling on live resources (idle plus checked out).
  final int maxConnections;

  /// How long [acquire] waits for a free slot before giving up with a 503.
  final Duration acquireTimeout;

  final ListQueue<C> _idle = ListQueue<C>();
  final ListQueue<Completer<void>> _waiters = ListQueue<Completer<void>>();

  /// Free slots. A slot is held from the moment a checkout is granted until the
  /// resource is released, so this bounds concurrent checkouts to
  /// [maxConnections] regardless of how many resources have actually been
  /// opened.
  late int _permits = maxConnections;
  int _checkedOut = 0;
  bool _closed = false;
  Completer<void>? _drained;

  /// Resources currently checked out (for tests and diagnostics).
  int get checkedOut => _checkedOut;

  /// Resources sitting idle, ready to be reused (for tests and diagnostics).
  int get idle => _idle.length;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

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
    if (_idle.isNotEmpty) return _idle.removeLast();
    try {
      return await _open();
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
  void release(C resource, {bool broken = false}) {
    _checkedOut--;
    if (broken || _closed) {
      unawaited(_safeClose(resource));
    } else {
      _idle.add(resource);
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
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(
        StateError('the connection pool is closed'),
      );
    }
    final idle = _idle.toList(growable: false);
    _idle.clear();
    for (final resource in idle) {
      await _safeClose(resource);
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
}
