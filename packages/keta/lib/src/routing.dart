/// Routing values. Both the string syntax and the typed DSL converge on a
/// single [Path] value whose type parameter is the tuple of its captures.
library;

import 'response.dart';

/// A single capture in a path — the public extension point for typed path
/// parameters.
///
/// [parse] turns the raw segment string into `T`. Its contract: throw
/// [BadRequest] on invalid input (→ 400); every other exception is a defect
/// (→ 500). [name] labels the parameter for OpenAPI (default `p0`, `p1`, …).
/// [schema] is the JSON-Schema fragment projected onto the OpenAPI parameter,
/// carried as data. A custom capture is a `parse` + `schema` pair:
///
/// ```dart
/// final role = Capture<Role>(
///     (s) => Role.values.asNameMap()[s] ?? (throw BadRequest('unknown role: $s')),
///     schema: {'type': 'string', 'enum': ['admin', 'member']});
/// ```
class Capture<T> {
  const Capture(this.parse, {this.name, required this.schema});
  final T Function(String) parse;
  final String? name;
  final Map<String, Object?> schema;

  /// A named copy, for OpenAPI parameter naming: `integer('id')`. Calling the
  /// capture is the one naming form — there is no separate `named()` helper.
  Capture<T> call(String name) => Capture<T>(parse, name: name, schema: schema);
}

// Built-in captures wrap the SDK's parse failures into a [BadRequest] here, once
// and inside the framework, so the parse contract (invalid input → 400) holds
// without the router special-casing FormatException.
String _identity(String s) => s;
int _toInt(String s) =>
    int.tryParse(s) ?? (throw BadRequest('not an integer: "$s"'));
double _toDouble(String s) =>
    double.tryParse(s) ?? (throw BadRequest('not a number: "$s"'));
bool _toBool(String s) => switch (s) {
  'true' => true,
  'false' => false,
  _ => throw BadRequest('not a boolean: "$s"'),
};

/// Built-in captures, exposed as top-level constants. The four names match the
/// OpenAPI types they project — a convenience, not a separate vocabulary.
const Capture<String> string = Capture(_identity, schema: {'type': 'string'});
const Capture<int> integer = Capture(_toInt, schema: {'type': 'integer'});
const Capture<double> number = Capture(_toDouble, schema: {'type': 'number'});
const Capture<bool> boolean = Capture(_toBool, schema: {'type': 'boolean'});

/// One path segment: a fixed literal or a capture.
sealed class Segment {
  const Segment();
}

class LiteralSegment extends Segment {
  const LiteralSegment(this.value);
  final String value;
}

class CaptureSegment extends Segment {
  const CaptureSegment(this.capture);
  final Capture<Object?> capture;
}

/// A path whose type parameter `T` is the tuple of its captures. Built by
/// chaining [segments] and `capture` from [root]; only [root] is `const`.
class Path<T> {
  const Path._(this.parts, this.buildTuple);

  /// The ordered path parts (literals and captures).
  final List<Segment> parts;

  /// Rebuilds the tuple `T` from the ordered, already-parsed capture values.
  /// Arity-specific; supplied by the `capture` extensions.
  final T Function(List<Object?> parsed) buildTuple;

  /// Appends one or more literal segments from a `/`-separated [run]
  /// (`'api/v1/users'`). Arity-preserving, so one call may swallow any number of
  /// segments without touching the type machinery. An empty part (a leading,
  /// trailing, or doubled `/`) or a `:`-prefixed part (string-syntax vocabulary)
  /// is an [ArgumentError] at construction.
  Path<T> segments(String run) {
    final added = <Segment>[];
    for (final part in run.split('/')) {
      if (part.isEmpty) {
        throw ArgumentError.value(run, 'run', 'empty path segment');
      }
      if (part.startsWith(':')) {
        throw ArgumentError.value(
          run,
          'run',
          'segments() takes literals; use capture() for parameters',
        );
      }
      added.add(LiteralSegment(part));
    }
    return Path<T>._([...parts, ...added], buildTuple);
  }

  /// The captures, in path order.
  Iterable<Capture<Object?>> get captures =>
      parts.whereType<CaptureSegment>().map((s) => s.capture);
}

() _unit(List<Object?> parsed) => ();

/// The empty path. Everything else is chained from here.
const Path<()> root = Path<()>._(<Segment>[], _unit);

// Arity-transition extensions, fixed 0–4. Each rebuilds the whole tuple from
// the full ordered capture list, so indices stay stable across `segments`.

extension PathCapture0 on Path<()> {
  Path<(A,)> capture<A>(Capture<A> capture) => Path<(A,)>._([
    ...parts,
    CaptureSegment(capture),
  ], (parsed) => (parsed[0] as A,));
}

extension PathCapture1<A> on Path<(A,)> {
  Path<(A, B)> capture<B>(Capture<B> capture) => Path<(A, B)>._([
    ...parts,
    CaptureSegment(capture),
  ], (parsed) => (parsed[0] as A, parsed[1] as B));
}

extension PathCapture2<A, B> on Path<(A, B)> {
  Path<(A, B, C)> capture<C>(Capture<C> capture) => Path<(A, B, C)>._([
    ...parts,
    CaptureSegment(capture),
  ], (parsed) => (parsed[0] as A, parsed[1] as B, parsed[2] as C));
}

extension PathCapture3<A, B, C> on Path<(A, B, C)> {
  Path<(A, B, C, D)> capture<D>(Capture<D> capture) => Path<(A, B, C, D)>._(
    [...parts, CaptureSegment(capture)],
    (parsed) =>
        (parsed[0] as A, parsed[1] as B, parsed[2] as C, parsed[3] as D),
  );
}

/// Desugars a string pattern such as `'/users/:id'` into a [Path]. Every
/// `:name` becomes a `Capture<String>`; typed parsing happens later at
/// `c.param<T>`. The result is `Path<dynamic>` — the string form never drives
/// the typed two-argument handler.
/// The path a list of already-built [Segment]s denotes — a shape that is data
/// (read from a file tree, a stored table, a config) rather than a written chain
/// of [Path.segments] and `capture` calls.
///
/// It carries no tuple, because a shape known only at runtime has no static
/// arity to build one from. That is why this is deliberately NOT exported from
/// `package:keta/keta.dart`: the only public door to it is `app.get(segments,
/// handler)` and friends, which take a plain [Handler] and read captures with
/// `c.param`. `on()` takes a `Path<T>` and so cannot be reached this way, which
/// makes "a data-shaped path has no tuple" a fact the compiler enforces rather
/// than a rule a comment asks for.
Path<dynamic> pathOfSegments(List<Segment> parts) =>
    Path<dynamic>._(parts, _noTuple);

Never _noTuple(List<Object?> parsed) => throw StateError(
  'a path built from segments has no tuple; this is unreachable through the '
  'public API and means keta built one and then asked it for one',
);

/// Parses the string routing syntax. Every capture is a [string]: the syntax has
/// no vocabulary for a type, which is why the typed DSL exists.
Path<dynamic> parsePathString(String pattern) {
  var path = root as Path<dynamic>;
  for (final raw in _splitSegments(pattern)) {
    if (raw.startsWith(':')) {
      final name = raw.substring(1);
      if (name.isEmpty) {
        throw ArgumentError.value(pattern, 'pattern', 'empty capture name');
      }
      path = _appendCapture(path, string(name));
    } else {
      path = path.segments(raw);
    }
  }
  return path;
}

/// Appends a capture to a `Path<dynamic>` without changing the static type
/// (the string syntax carries no tuple; captures are read via `c.param`).
Path<dynamic> _appendCapture(Path<dynamic> path, Capture<Object?> capture) =>
    Path<dynamic>._([...path.parts, CaptureSegment(capture)], path.buildTuple);

Iterable<String> _splitSegments(String pattern) =>
    pattern.split('/').where((s) => s.isNotEmpty);

/// The human-readable template of [segments]: literals verbatim, captures as
/// `:name`. Used for log and access-log route fields.
String templateOf(List<Segment> segments) {
  if (segments.isEmpty) return '/';
  final buf = StringBuffer();
  var index = 0;
  for (final s in segments) {
    buf.write('/');
    switch (s) {
      case LiteralSegment(:final value):
        buf.write(value);
      case CaptureSegment(:final capture):
        buf.write(':${capture.name ?? 'p$index'}');
        index++;
    }
  }
  return buf.toString();
}

/// The route-conflict key: literals verbatim, every capture collapsed to `*`
/// so two routes that differ only in capture names count as a conflict.
///
/// Exported because `App.compile` is not the only place that needs to decide
/// whether two routes are "the same route": an OpenAPI emitter walking a
/// route table independently (keta_openapi's `OpenApi.fromRoutes`, which can
/// run standalone without a live [App]) must reject the same pair `App.compile`
/// would reject and merge into one document path item everything `App.compile`
/// would treat as one route — `/users/:id` and `/users/:userId` are one
/// conflict, not two OpenAPI paths, because a request can only ever match one
/// of them. This is the single public source both read; there is no longer a
/// copy anywhere to drift.
String conflictKey(String method, List<Segment> segments) {
  final buf = StringBuffer(method);
  for (final s in segments) {
    buf.write('/');
    buf.write(s is LiteralSegment ? s.value : '*');
  }
  return buf.toString();
}
