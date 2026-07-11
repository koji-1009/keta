library;

import 'dart:async';

/// Applies [f] to [v] without awaiting when [v] is already a plain value, so
/// a fully synchronous chain allocates no [Future].
FutureOr<R> chain<T, R>(FutureOr<T> v, FutureOr<R> Function(T) f) =>
    v is Future<T> ? v.then(f) : f(v);

/// Runs [run] and routes both a synchronous `throw` and a rejected [Future]
/// through the single [onError] path, so callers handle failure in one place.
FutureOr<R> guard<R>(
  FutureOr<R> Function() run,
  R Function(Object error, StackTrace stackTrace) onError,
) {
  try {
    final result = run();
    if (result is Future<R>) {
      return result.then<R>((v) => v, onError: onError);
    }
    return result;
  } catch (e, st) {
    return onError(e, st);
  }
}
