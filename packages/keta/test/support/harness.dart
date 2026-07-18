/// Shared test harness: the common [Env]/[Log] fakes and single-middleware
/// runners every keta test builds on, so one fixture lives here instead of a
/// copy per file.
library;

import 'package:keta/keta.dart';

/// A [Log] that records every emitted line in memory, so a test can assert on
/// exactly what a middleware wrote. `withFields` returns a view that keeps
/// recording into the same store, the way a real per-request logger does.
class MemLog implements Log {
  MemLog([this.lines = const []]) : _baked = const {};
  MemLog._(this.lines, this._baked);
  final List<Map<String, Object?>> lines;
  final Map<String, Object?> _baked;

  void _add(String level, String msg, Map<String, Object?> fields) =>
      lines.add({'level': level, 'msg': msg, ..._baked, ...fields});

  @override
  void debug(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('debug', msg, fields);
  @override
  void info(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('info', msg, fields);
  @override
  void warn(String msg, [Map<String, Object?> fields = const {}]) =>
      _add('warn', msg, fields);
  @override
  void error(
    String msg, [
    Object? error,
    StackTrace? st,
    Map<String, Object?> fields = const {},
  ]) => _add('error', msg, {...fields, if (error != null) 'error': '$error'});
  @override
  Future<void> flush() async {}
  @override
  Log withFields(Map<String, Object?> fields) =>
      MemLog._(lines, {..._baked, ...fields});
}

/// The minimal environment keta's generic parameter needs: it carries a [Log].
class Env implements HasLog {
  Env(this.log);
  @override
  final Log log;
}

/// A fresh environment whose log is an inspectable [MemLog]. Tests that never
/// read the log simply ignore it; those that do cast `env.log as MemLog`.
Env newEnv() => Env(MemLog(<Map<String, Object?>>[]));

/// The per-isolate boot used by tests that stand up a real server: a plain,
/// immediately-flushing [StdoutLog] rather than an in-memory recorder.
Future<Env> boot() async => Env(StdoutLog(flushInterval: Duration.zero));

/// Runs [mw] against a fixed [response] handler and returns what it produced —
/// the single-middleware harness used to assert a middleware's behavior in
/// isolation. Deliberately non-generic (bound to [Env]) so callers keep full
/// type inference at the call site; a generic version regressed inference of
/// `cors(...)`/`testContext(...)` arguments to `dynamic`.
Future<Response> run(Middleware<Env> mw, Context<Env> c, Response response) =>
    Future.value(mw(c, (_) => response));

/// Alias of [run] under the name some suites already use for the same harness.
Future<Response> runMw(Middleware<Env> mw, Context<Env> c, Response response) =>
    Future.value(mw(c, (_) => response));
